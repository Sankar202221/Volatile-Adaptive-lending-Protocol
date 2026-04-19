// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../BaseTest.sol";
import {VolatilityOracle} from "../../src/VolatilityOracle.sol";

contract VolatilityOracleTest is Test {
    uint256 constant WAD = 1e18;

    VolatilityOracle internal realOracle;
    address          internal feeder = makeAddr("feeder");

    function setUp() public {
        realOracle = new VolatilityOracle(feeder);
    }

    // ── Price recording ───────────────────────────────────────────────────────

    function test_RecordPrice_Succeeds() public {
        vm.prank(feeder);
        realOracle.recordPrice(2000 ether);
        assertEq(realOracle.latestPrice(), 2000 ether);
    }

    function test_RecordPrice_Revert_Unauthorized() public {
        vm.expectRevert(VolatilityOracle.Unauthorized.selector);
        vm.prank(makeAddr("rando"));
        realOracle.recordPrice(2000 ether);
    }

    function test_RecordPrice_Revert_TooFrequent() public {
        vm.prank(feeder);
        realOracle.recordPrice(2000 ether);

        // Same second
        vm.expectRevert(VolatilityOracle.TooFrequent.selector);
        vm.prank(feeder);
        realOracle.recordPrice(2001 ether);
    }

    function test_RecordPrice_Revert_DeviationTooHigh() public {
        vm.prank(feeder);
        realOracle.recordPrice(2000 ether);

        // Try to jump > 20%
        skip(10);
        vm.expectRevert(VolatilityOracle.PriceDeviationTooHigh.selector);
        vm.prank(feeder);
        realOracle.recordPrice(2500 ether);  // 25% jump
    }

    // ── Volatility computation ────────────────────────────────────────────────

    function test_Volatility_Revert_InsufficientData() public {
        vm.expectRevert(VolatilityOracle.InsufficientData.selector);
        realOracle.getVolatility();

        vm.prank(feeder);
        realOracle.recordPrice(2000 ether);

        // Still only 1 point
        vm.expectRevert(VolatilityOracle.InsufficientData.selector);
        realOracle.getVolatility();
    }

    function test_Volatility_ZeroForConstantPrice() public {
        uint256 price = 2000 ether;
        for (uint256 i = 0; i < 5; i++) {
            skip(10);
            vm.prank(feeder);
            realOracle.recordPrice(price);
        }
        // Read within the staleness window (< 1 hour since last update)
        uint256 vol = realOracle.getVolatility();
        assertEq(vol, 0, "zero vol for constant price");
    }

    function test_Volatility_HigherForMoreVolatilePrice() public {
        // Stable scenario
        for (uint256 i = 0; i < 6; i++) {
            skip(10);
            vm.prank(feeder);
            realOracle.recordPrice(2000 ether + i * 1 ether);  // tiny moves
        }
        // Read within 1 hour of last update
        uint256 stableVol = realOracle.getVolatility();

        // Reset oracle
        realOracle = new VolatilityOracle(feeder);

        // Volatile scenario (oscillate ~5%)
        uint256 base = 2000 ether;
        for (uint256 i = 0; i < 6; i++) {
            skip(10);
            vm.prank(feeder);
            uint256 p = i % 2 == 0 ? base : base - (base / 20); // 5% swings
            realOracle.recordPrice(p);
        }
        // Read within 1 hour of last update
        uint256 volatileVol = realOracle.getVolatility();

        assertGt(volatileVol, stableVol, "higher vol for volatile prices");
    }

    function test_Volatility_CappedAtWAD() public {
        // Fill with maximum swings (just under 20% per update)
        uint256 p = 2000 ether;
        for (uint256 i = 0; i < VolatilityOracle(realOracle).WINDOW_SIZE(); i++) {
            skip(10);
            vm.prank(feeder);
            realOracle.recordPrice(p);
            // Alternate down/up by ~19%
            p = i % 2 == 0
                ? (p * 8100) / 10_000   // -19%
                : (p * 12345) / 10_000; // +23% → clipped to 20% by guard
        }
        uint256 vol = realOracle.getVolatility();
        assertLe(vol, WAD, "vol capped at WAD");
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function test_SetFeeder_Timelock() public {
        address newFeeder = makeAddr("new_feeder");

        // Queue the new feeder
        realOracle.setFeeder(newFeeder);
        assertEq(realOracle.pendingFeeder(), newFeeder, "pending feeder set");
        assertEq(realOracle.feeder(),        feeder,    "feeder unchanged yet");

        // Cannot apply before delay
        vm.expectRevert(VolatilityOracle.FeederNotReady.selector);
        realOracle.applyFeeder();

        // Apply after 1-day timelock
        skip(1 days + 1);
        realOracle.applyFeeder();
        assertEq(realOracle.feeder(), newFeeder, "feeder updated after timelock");
    }

    function test_SetFeeder_Revert_NonOwner() public {
        vm.expectRevert(VolatilityOracle.Unauthorized.selector);
        vm.prank(feeder);
        realOracle.setFeeder(feeder);
    }

    /// @notice Issue 5 fix: getVolatility() must revert StaleData when the newest
    ///         snapshot is older than STALENESS_THRESHOLD (1 hour).
    function test_Oracle_StaleData_Reverts() public {
        // Record two prices so the oracle has sufficient data
        vm.prank(feeder); realOracle.recordPrice(2000 ether);
        skip(10);
        vm.prank(feeder); realOracle.recordPrice(2010 ether);

        // Within freshness window — call succeeds
        realOracle.getVolatility();

        // Advance past the staleness threshold (1 hour)
        skip(realOracle.STALENESS_THRESHOLD() + 1);

        vm.expectRevert(VolatilityOracle.StaleData.selector);
        realOracle.getVolatility();
    /// @notice When the oracle is unavailable _safeVolatility() returns WAD (fail-closed).
    ///         The pool's borrow rate must then be elevated above the zero-vol baseline.
    function test_Oracle_FailClosed_ElevatesRate() public {
        // Build a pool pointing at the real oracle (no data recorded -> InsufficientData revert)
        MockERC20         tok = new MockERC20("T", "T");
        InterestRateModel rm  = new InterestRateModel();
        RiskManager       ris = new RiskManager(address(realOracle), address(this));
        LendingPool       p   = new LendingPool(address(tok), address(ris), address(rm), address(realOracle));

        // Rate with oracle failure (vol = WAD from _safeVolatility fail-closed)
        uint256 rateWithOracleFailure = p.currentBorrowRate();

        // Baseline at vol = 0
        uint256 rateAtZeroVol = rm.getBorrowRate(0, 0);

        // Oracle failure must produce a HIGHER rate, not silently use zero vol
        assertGt(rateWithOracleFailure, rateAtZeroVol, "fail-closed elevates borrow rate");
    }
}

