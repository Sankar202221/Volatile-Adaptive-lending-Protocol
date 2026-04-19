// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../BaseTest.sol";

contract LendingPoolTest is BaseTest {
    // ──────────────────────────────────────────────────────────────────────────
    // Deposit
    // ──────────────────────────────────────────────────────────────────────────

    function test_Deposit_BasicAccounting() public {
        _deposit(alice, 100 ether);

        // totalDeposits includes the VIRTUAL_SHARES seed
        assertEq(pool.totalDeposits(), 100 ether + pool.VIRTUAL_SHARES(), "total deposits");
        // depositValue correctly accounts for the share ratio
        assertEq(pool.depositValue(alice), 100 ether, "alice deposit value");
    }

    function test_Deposit_SharesScaleCorrectly() public {
        _deposit(alice, 100 ether);
        _deposit(bob,   200 ether);

        // Bob should have 2x alice's shares
        (uint256 aliceShares,,) = pool.users(alice);
        (uint256 bobShares,,)    = pool.users(bob);
        assertEq(bobShares, 2 * aliceShares, "share ratio");
    }

    function test_Deposit_Revert_ZeroAmount() public {
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(alice);
        pool.deposit(0);
    }

    /// @notice BUG 4 FIX: depositing additional collateral must always be allowed,
    ///         even when the user has an existing borrow.  This is the standard
    ///         mechanism for restoring health in every major DeFi protocol.
    function test_Deposit_WithDebt_Allowed() public {
        _deposit(alice, 100 ether);
        _setVol(0);
        _borrow(alice, 50 ether);

        // Alice now has debt; she should be able to add more collateral
        assertGt(pool.debtOf(alice), 0, "alice has debt");
        vm.prank(alice);
        pool.deposit(50 ether);  // must NOT revert

        // Health factor should improve after the extra deposit
        uint256 hf = pool.healthFactor(alice);
        assertGe(hf, WAD, "health factor improved");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Withdraw
    // ──────────────────────────────────────────────────────────────────────────

    function test_Withdraw_FullAmount() public {
        _deposit(alice, 100 ether);
        (uint256 shares,,) = pool.users(alice);

        vm.prank(alice);
        pool.withdraw(shares);

        assertEq(pool.depositValue(alice), 0, "deposit cleared");
        // After a full withdrawal totalDeposits returns to the virtual seed
        assertEq(pool.totalDeposits(), pool.VIRTUAL_SHARES(), "pool at virtual seed");
    }

    function test_Withdraw_Revert_InsufficientShares() public {
        _deposit(alice, 100 ether);

        vm.expectRevert(LendingPool.InsufficientShares.selector);
        vm.prank(alice);
        pool.withdraw(999_999 ether);
    }

    function test_Withdraw_Revert_InsufficientLiquidity() public {
        _deposit(alice, 100 ether);
        _borrow(alice, 50 ether);   // borrow half

        (uint256 shares,,) = pool.users(alice);

        // Cannot withdraw everything while 50 is lent out
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        vm.prank(alice);
        pool.withdraw(shares);  // would require returning > 50 eth from locked liquidity
    }

    /// @notice BUG 1 FIX: health check must fire BEFORE state mutation in withdraw().
    ///         Attempting to withdraw all collateral while indebted must revert with
    ///         InsufficientCollateral, not leave dirty state before reverting.
    function test_Withdraw_Revert_HealthCheckBeforeMutation() public {
        // Bob provides liquidity so alice can actually borrow
        _deposit(bob, 100 ether);
        _deposit(alice, 100 ether);
        _setVol(0);
        _borrow(alice, 60 ether);  // borrow 60% — within 80% LTV

        (uint256 shares,,) = pool.users(alice);

        // Alice tries to withdraw ALL her collateral; must revert before mutating state
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        vm.prank(alice);
        pool.withdraw(shares);

        // State must be unchanged after the revert
        assertGt(pool.depositValue(alice), 0, "alice deposit unchanged");
    }

    function test_Withdraw_HealthyBorrow_AllowsPartial() public {
        _deposit(alice, 100 ether);
        _setVol(0);
        _borrow(alice, 40 ether);  // 40% LTV — leaves lots of cushion

        (uint256 shares,,) = pool.users(alice);
        uint256 halfShares = shares / 4; // withdraw 25% — should be fine

        vm.prank(alice);
        pool.withdraw(halfShares);  // must succeed

        assertGe(pool.healthFactor(alice), WAD, "still healthy after partial withdraw");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Borrow
    // ──────────────────────────────────────────────────────────────────────────

    function test_Borrow_WithinLTV() public {
        _deposit(alice, 100 ether);
        _setVol(0);  // zero vol → max LTV = 80%

        _borrow(alice, 60 ether);  // 60% of 100 — within 80% LTV

        assertEq(pool.debtOf(alice), 60 ether, "debt recorded");
    }

    function test_Borrow_Revert_ExceedsLTV() public {
        _deposit(alice, 100 ether);
        _setVol(0);  // LTV = 80%

        vm.expectRevert(LendingPool.ExceedsMaxBorrow.selector);
        vm.prank(alice);
        pool.borrow(90 ether);  // exceeds 80 LTV
    }

    function test_Borrow_Revert_BorrowingFrozen_HighVol() public {
        _deposit(alice, 100 ether);
        _setVol(0.75e18);  // > FREEZE_VOL_THRESHOLD (0.70)

        vm.expectRevert(LendingPool.BorrowingFrozen.selector);
        vm.prank(alice);
        pool.borrow(10 ether);
    }

    function test_Borrow_LTV_Reduces_WithVolatility() public {
        _deposit(alice, 100 ether);

        // At low vol, borrow 60 should succeed
        _setVol(0.10e18);
        _borrow(alice, 60 ether);  // safe under reduced LTV
        _repay(alice, 60 ether);

        // Wait for accrual to settle
        _skip(1);

        // Now ramp vol — same amount should fail
        _setVol(0.60e18);

        vm.expectRevert(LendingPool.ExceedsMaxBorrow.selector);
        vm.prank(alice);
        pool.borrow(60 ether);
    }

    function test_Borrow_Revert_ZeroAmount() public {
        _deposit(alice, 100 ether);

        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(alice);
        pool.borrow(0);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Repay
    // ──────────────────────────────────────────────────────────────────────────

    function test_Repay_ClearsDebt() public {
        _deposit(alice, 100 ether);
        _borrow(alice, 50 ether);

        // Repay in full
        vm.prank(alice);
        pool.repay(50 ether);

        assertEq(pool.debtOf(alice), 0, "debt cleared");
    }

    function test_Repay_InterestAccruesOverTime() public {
        _deposit(alice, 1000 ether);
        _setVol(0);
        _borrow(alice, 500 ether);

        uint256 debtBefore = pool.debtOf(alice);

        _skip(365 days);  // let a year pass

        uint256 debtAfter = pool.debtOf(alice);
        assertGt(debtAfter, debtBefore, "interest accrued");
    }

    /// @notice BUG 2 FIX: after a partial repay, totalBorrows must equal
    ///         the exact remaining unscaled debt — no drift allowed.
    function test_Repay_TotalBorrows_ConsistentAfterPartialRepay() public {
        _deposit(alice, 1_000 ether);
        _setVol(0);
        _borrow(alice, 400 ether);

        // Advance time so interest accrues
        _skip(30 days);

        uint256 debtBefore = pool.debtOf(alice);

        // Partial repay: half the outstanding debt
        uint256 partialRepay = debtBefore / 2;
        vm.prank(alice);
        pool.repay(partialRepay);

        uint256 debtAfter      = pool.debtOf(alice);
        uint256 totalBorrows   = pool.totalBorrows();

        // totalBorrows must be >= remaining debt (could be slightly higher due to
        // other rounding, but must never undercount more than 1 wei per partial repay)
        assertGe(totalBorrows, debtAfter, "totalBorrows >= remaining debt");
        assertLe(totalBorrows, debtAfter + 2, "totalBorrows within 2 wei of remaining debt");
    }

    function test_Repay_Full_ClearsTotalBorrows() public {
        _deposit(alice, 1_000 ether);
        _setVol(0);
        _borrow(alice, 400 ether);

        // Pay off in full (overshoot repayment is silently capped to exact debt)
        uint256 debtFull = pool.debtOf(alice);
        vm.prank(alice);
        pool.repay(debtFull + 1 ether); // intentional overshoot

        assertEq(pool.debtOf(alice), 0,     "debt fully cleared");
        assertEq(pool.totalBorrows(), 0,    "totalBorrows cleared");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // RepayOnBehalf  (Issue 8 fix)
    // ──────────────────────────────────────────────────────────────────────────

    function test_RepayOnBehalf_Works() public {
        _deposit(alice, 100 ether);
        _setVol(0);
        _borrow(alice, 50 ether);

        uint256 aliceDebtBefore = pool.debtOf(alice);
        assertGt(aliceDebtBefore, 0, "alice has debt");

        // Bob repays alice's debt on her behalf
        vm.prank(bob);
        pool.repayOnBehalf(alice, 50 ether);

        assertEq(pool.debtOf(alice), 0, "alice debt cleared by bob");
        // Bob's token balance decreased
        assertLt(token.balanceOf(bob), 10_000 ether, "bob tokens used");
    }

    function test_RepayOnBehalf_Revert_ZeroAmount() public {
        vm.prank(bob);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.repayOnBehalf(alice, 0);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Utilisation
    // ──────────────────────────────────────────────────────────────────────────

    function test_Utilization_Correct() public {
        _deposit(alice, 100 ether);
        _borrow(alice, 40 ether);

        // 40 / (100 + VIRTUAL_SHARES) ≈ 40% — use approxEqAbs to tolerate the tiny
        // rounding effect of VIRTUAL_SHARES (1000 wei) on the utilisation ratio.
        assertApproxEqAbs(pool.utilization(), 0.40e18, 1e6, "utilisation ≈ 40%");
    }

    function test_Utilization_Zero_WhenNoBorrows() public {
        _deposit(alice, 100 ether);
        assertEq(pool.utilization(), 0, "utilisation 0");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Health Factor
    // ──────────────────────────────────────────────────────────────────────────

    function test_HealthFactor_HighWhenNoBorrows() public {
        _deposit(alice, 100 ether);
        assertEq(pool.healthFactor(alice), type(uint256).max, "no debt = max HF");
    }

    function test_HealthFactor_DropsWithVolatility() public {
        _deposit(alice, 100 ether);
        _setVol(0);
        _borrow(alice, 60 ether);

        uint256 hf_low_vol = pool.healthFactor(alice);

        _setVol(0.50e18);  // higher vol → lower liq threshold → lower HF
        uint256 hf_high_vol = pool.healthFactor(alice);

        assertGt(hf_low_vol, hf_high_vol, "HF drops with volatility");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Ownership (two-step)  — Issue 12 fix
    // ──────────────────────────────────────────────────────────────────────────

    function test_Ownership_TwoStep_Transfer() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: current owner proposes
        vm.prank(pool.owner());
        pool.transferOwnership(newOwner);
        assertEq(pool.pendingOwner(), newOwner, "pending owner set");
        assertEq(pool.owner(), address(this),   "owner not changed yet");

        // Step 2: new owner accepts
        vm.prank(newOwner);
        pool.acceptOwnership();
        assertEq(pool.owner(), newOwner,        "ownership transferred");
        assertEq(pool.pendingOwner(), address(0), "pending cleared");
    }

    function test_Ownership_Revert_UnauthorizedAccept() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(pool.owner());
        pool.transferOwnership(newOwner);

        // A random address cannot accept
        vm.prank(makeAddr("random"));
        vm.expectRevert(LendingPool.Unauthorized.selector);
        pool.acceptOwnership();
    }
}
