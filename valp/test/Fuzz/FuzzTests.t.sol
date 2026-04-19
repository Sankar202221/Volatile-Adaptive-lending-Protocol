// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../BaseTest.sol";

/// @title FuzzTests
/// @notice Property-based tests that explore arbitrary inputs.
///         Foundry runs each `testFuzz_*` function 1 000+ times with random args.
contract FuzzTests is BaseTest {
    // ──────────────────────────────────────────────────────────────────────────
    // Interest Rate Model
    // ──────────────────────────────────────────────────────────────────────────

    /// The borrow rate must always be within [MIN_RATE, MAX_RATE].
    function testFuzz_BorrowRate_AlwaysInBounds(
        uint256 utilization,
        uint256 volatility
    ) public {
        utilization = bound(utilization, 0, WAD);
        volatility  = bound(volatility,  0, WAD);

        uint256 rate = rateModel.getBorrowRate(utilization, volatility);

        assertGe(rate, rateModel.MIN_RATE(), "rate >= MIN");
        assertLe(rate, rateModel.MAX_RATE(), "rate <= MAX");
    }

    /// Higher utilisation should never yield a LOWER rate (monotone property).
    function testFuzz_BorrowRate_MonotoneInUtilisation(
        uint256 util1,
        uint256 util2,
        uint256 vol
    ) public {
        util1 = bound(util1, 0, WAD);
        util2 = bound(util2, 0, WAD);
        vol   = bound(vol,   0, WAD);

        uint256 r1 = rateModel.getBorrowRate(util1, vol);
        uint256 r2 = rateModel.getBorrowRate(util2, vol);

        if (util2 > util1) assertGe(r2, r1, "rate monotone in util");
    }

    /// Higher volatility should never yield a LOWER rate.
    function testFuzz_BorrowRate_MonotoneInVolatility(
        uint256 util,
        uint256 vol1,
        uint256 vol2
    ) public {
        util = bound(util, 0, WAD);
        vol1 = bound(vol1, 0, WAD);
        vol2 = bound(vol2, 0, WAD);

        uint256 r1 = rateModel.getBorrowRate(util, vol1);
        uint256 r2 = rateModel.getBorrowRate(util, vol2);

        if (vol2 > vol1) assertGe(r2, r1, "rate monotone in vol");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Risk Manager
    // ──────────────────────────────────────────────────────────────────────────

    /// LTV must always be in [MIN_LTV, BASE_LTV].
    function testFuzz_LTV_AlwaysInBounds(uint256 vol) public {
        vol = bound(vol, 0, WAD);
        _setVol(vol);

        uint256 ltv = riskManager.getLTV();

        assertGe(ltv, riskManager.MIN_LTV(), "LTV >= min");
        assertLe(ltv, riskManager.BASE_LTV(), "LTV <= base");
    }

    /// LTV must be non-increasing in volatility.
    function testFuzz_LTV_MonotoneInVolatility(uint256 vol1, uint256 vol2) public {
        vol1 = bound(vol1, 0, WAD);
        vol2 = bound(vol2, vol1, WAD);  // vol2 >= vol1

        _setVol(vol1);
        uint256 ltv1 = riskManager.getLTV();

        _setVol(vol2);
        uint256 ltv2 = riskManager.getLTV();

        assertGe(ltv1, ltv2, "LTV non-increasing in vol");
    }

    /// Liquidation penalty must always be in [BASE_PEN, MAX_PEN].
    function testFuzz_LiqPenalty_AlwaysInBounds(uint256 vol) public {
        vol = bound(vol, 0, WAD);
        _setVol(vol);

        uint256 penalty = riskManager.getLiquidationPenalty();

        assertGe(penalty, riskManager.BASE_PEN(), "penalty >= base");
        assertLe(penalty, riskManager.MAX_PEN(), "penalty <= max");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Lending Pool — Deposit / Withdraw
    // ──────────────────────────────────────────────────────────────────────────

    /// Depositing and immediately withdrawing all shares must return original tokens.
    function testFuzz_DepositWithdraw_Roundtrip(uint256 amount) public {
        amount = bound(amount, 1, 5_000 ether);

        uint256 balBefore = token.balanceOf(alice);

        _deposit(alice, amount);
        (uint256 shares,,) = pool.users(alice);
        vm.prank(alice);
        pool.withdraw(shares);

        uint256 balAfter = token.balanceOf(alice);
        assertEq(balAfter, balBefore, "roundtrip: no funds lost");
    }

    /// Pool's token balance must always equal totalDeposits - totalBorrows.
    function testFuzz_PoolBalance_ConsistentWithAccounting(
        uint256 depositAmt,
        uint256 borrowAmt
    ) public {
        depositAmt = bound(depositAmt, 100 ether, 5_000 ether);
        borrowAmt  = bound(borrowAmt,  1,          depositAmt * 79 / 100); // within ~LTV

        _setVol(0);
        _deposit(alice, depositAmt);
        _borrow(alice, borrowAmt);

        uint256 poolBalance = token.balanceOf(address(pool));
        assertEq(
            poolBalance,
            pool.totalDeposits() - pool.totalBorrows(),
            "pool balance == deposits - borrows"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Lending Pool — Borrow Safety
    // ──────────────────────────────────────────────────────────────────────────

    /// Borrow must always revert if amount exceeds current max.
    function testFuzz_Borrow_NeverExceedsMaxBorrow(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        _setVol(0);
        _deposit(alice, 100 ether);

        uint256 maxBorrow = riskManager.getMaxBorrowValue(pool.depositValue(alice));

        if (amount > maxBorrow) {
            vm.expectRevert();
        }
        vm.prank(alice);
        pool.borrow(amount);
    }

    /// After any valid borrow, health factor must remain >= 1 immediately.
    function testFuzz_Borrow_HealthFactorAlwaysSafe(uint256 vol, uint256 pct) public {
        vol = bound(vol, 0, 0.65e18);  // below freeze threshold
        pct = bound(pct, 1, 98);        // borrow pct% of max

        _setVol(vol);
        _deposit(alice, 1000 ether);

        uint256 maxBorrow = riskManager.getMaxBorrowValue(pool.depositValue(alice));
        uint256 borrowAmt = (maxBorrow * pct) / 100;
        if (borrowAmt == 0) return;

        _borrow(alice, borrowAmt);

        uint256 hf = pool.healthFactor(alice);
        assertGe(hf, WAD, "HF must be safe after valid borrow");
    }
}
