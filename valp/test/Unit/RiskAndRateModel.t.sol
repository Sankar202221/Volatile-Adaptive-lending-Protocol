// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../BaseTest.sol";

// ── RiskManager ───────────────────────────────────────────────────────────────

contract RiskManagerTest is BaseTest {
    uint256 constant BASE_LTV = 0.80e18;

    function test_LTV_AtZeroVolatility() public {
        _setVol(0);
        assertEq(riskManager.getLTV(), BASE_LTV, "LTV = base at 0 vol");
    }

    function test_LTV_DecreasesWithVolatility() public {
        _setVol(0.20e18);
        uint256 ltv = riskManager.getLTV();
        assertLt(ltv, BASE_LTV, "LTV < base when vol > 0");
    }

    function test_LTV_NeverBelowMinimum() public {
        _setVol(WAD);  // maximum possible volatility
        uint256 ltv = riskManager.getLTV();
        assertGe(ltv, riskManager.MIN_LTV(), "LTV >= MIN_LTV");
    }

    function test_LiquidationThreshold_BelowLTV() public {
        _setVol(0);
        uint256 liq = riskManager.getLiquidationThreshold();
        uint256 ltv = riskManager.getLTV();
        assertGt(liq, ltv, "liqThreshold > ltv");
    }

    function test_LiquidationPenalty_GrowsWithVol() public {
        _setVol(0);
        uint256 penLow  = riskManager.getLiquidationPenalty();
        _setVol(0.50e18);
        uint256 penHigh = riskManager.getLiquidationPenalty();
        assertGt(penHigh, penLow, "penalty grows with volatility");
    }

    function test_LiquidationPenalty_NeverExceedsMax() public {
        _setVol(WAD);
        uint256 pen = riskManager.getLiquidationPenalty();
        assertLe(pen, riskManager.MAX_PEN(), "penalty capped");
    }

    function test_BorrowingFrozen_AboveThreshold() public {
        _setVol(0.71e18);
        assertTrue(riskManager.isBorrowingFrozen(), "frozen above threshold");
    }

    function test_BorrowingNotFrozen_BelowThreshold() public {
        _setVol(0.69e18);
        assertFalse(riskManager.isBorrowingFrozen(), "not frozen below threshold");
    }

    function test_HealthFactor_InfiniteWhenNoDebt() public {
        uint256 hf = riskManager.getHealthFactor(100 ether, 0);
        assertEq(hf, type(uint256).max, "no debt = max HF");
    }

    function test_HealthFactor_BelowOne_WhenUndercollateralised() public {
        _setVol(0);
        // liqThreshold = 85%
        // HF = 100 * 0.85 / 90 = 0.94 < 1
        uint256 hf = riskManager.getHealthFactor(100 ether, 90 ether);
        assertLt(hf, WAD, "undercollateralised");
    }

    function test_IsLiquidatable_WhenHFLow() public {
        _setVol(0);
        bool liq = riskManager.isLiquidatable(100 ether, 90 ether);
        assertTrue(liq, "should be liquidatable");
    }

    function test_IsNotLiquidatable_WhenHFHigh() public {
        _setVol(0);
        bool liq = riskManager.isLiquidatable(100 ether, 50 ether);
        assertFalse(liq, "should not be liquidatable");
    }
}

// ── InterestRateModel ─────────────────────────────────────────────────────────

contract InterestRateModelTest is BaseTest {
    function test_Rate_AtZeroUtilAndVol() public {
        uint256 rate = rateModel.getBorrowRate(0, 0);
        assertEq(rate, rateModel.BASE_RATE(), "base rate at zero");
    }

    function test_Rate_IncreasesWithUtilisation() public {
        uint256 low  = rateModel.getBorrowRate(0.20e18, 0);
        uint256 high = rateModel.getBorrowRate(0.80e18, 0);
        assertGt(high, low, "rate increases with utilisation");
    }

    function test_Rate_JumpsAboveKink() public {
        uint256 atKink    = rateModel.getBorrowRate(rateModel.KINK(), 0);
        uint256 aboveKink = rateModel.getBorrowRate(rateModel.KINK() + 0.01e18, 0);
        // slope jumps from SLOPE_1 to SLOPE_2 above kink
        assertGt(aboveKink - atKink, 0, "slope jump at kink");
    }

    function test_Rate_IncreasesWithVolatility() public {
        uint256 lowVol  = rateModel.getBorrowRate(0.50e18, 0);
        uint256 highVol = rateModel.getBorrowRate(0.50e18, 0.50e18);
        assertGt(highVol, lowVol, "vol premium adds to rate");
    }

    function test_Rate_NeverBelowMin() public {
        uint256 rate = rateModel.getBorrowRate(0, 0);
        assertGe(rate, rateModel.MIN_RATE(), "rate >= MIN_RATE");
    }

    function test_Rate_NeverAboveMax() public {
        uint256 rate = rateModel.getBorrowRate(WAD, WAD);
        assertLe(rate, rateModel.MAX_RATE(), "rate <= MAX_RATE");
    }

    function test_SupplyRate_LowerThanBorrowRate() public {
        uint256 borrow = rateModel.getBorrowRate(0.80e18, 0.20e18);
        uint256 supply = rateModel.getSupplyRate(0.80e18, 0.20e18);
        assertLt(supply, borrow, "supply < borrow (spread exists)");
    }

    // ── Timelock (Issue 11 fix) ───────────────────────────────────────────────

    /// @notice Owner cannot instantly change reserveFactor; must queue then wait.
    function test_ReserveFactor_RequiresTimelock() public {
        uint256 newFactor = 0.20e18;

        // Direct update no longer exists — must queue
        rateModel.queueReserveFactorUpdate(newFactor);
        assertEq(rateModel.reserveFactor(), 0.10e18, "factor unchanged before timelock");

        // Cannot execute before delay
        vm.expectRevert(InterestRateModel.TimelockActive.selector);
        rateModel.executeReserveFactorUpdate();

        // Apply after 2-day timelock
        skip(2 days + 1);
        rateModel.executeReserveFactorUpdate();
        assertEq(rateModel.reserveFactor(), newFactor, "factor updated after timelock");
    }

    function test_ReserveFactor_Revert_NoPendingUpdate() public {
        vm.expectRevert(InterestRateModel.NoPendingUpdate.selector);
        rateModel.executeReserveFactorUpdate();
    }

    function test_ReserveFactor_Revert_Unauthorized() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(InterestRateModel.Unauthorized.selector);
        rateModel.queueReserveFactorUpdate(0.50e18);
    }

    // ── Two-step ownership (Issue 12 fix) ────────────────────────────────────

    function test_Ownership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        rateModel.transferOwnership(newOwner);
        assertEq(rateModel.pendingOwner(), newOwner,        "pending set");
        assertEq(rateModel.owner(),        address(this),  "owner unchanged");

        vm.prank(newOwner);
        rateModel.acceptOwnership();
        assertEq(rateModel.owner(),        newOwner,        "ownership transferred");
        assertEq(rateModel.pendingOwner(), address(0),      "pending cleared");
    }

    function test_Ownership_Revert_UnauthorizedAccept() public {
        address newOwner = makeAddr("newOwner");
        rateModel.transferOwnership(newOwner);

        vm.prank(makeAddr("impostor"));
        vm.expectRevert(InterestRateModel.Unauthorized.selector);
        rateModel.acceptOwnership();
    }

    /// @notice getBorrowRate must cap over-utilised input rather than revert,
    ///         so the accrual loop is never bricked (Issue 14 fix).
    function test_BorrowRate_CapsOverUtilizedInput() public {
        // Should NOT revert even with utilization > WAD
        uint256 rate = rateModel.getBorrowRate(2e18, 0);
        assertLe(rate, rateModel.MAX_RATE(), "rate capped at max");
    }
}
