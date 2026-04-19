// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LendingPool}          from "../../src/LendingPool.sol";
import {MockVolatilityOracle} from "../../src/mocks/MockVolatilityOracle.sol";
import {MockERC20}            from "../../src/mocks/MockERC20.sol";

/// @title Handler
/// @notice Simulates random user actions for invariant testing.
///         Foundry calls these functions in random sequences to find
///         state inconsistencies.
contract Handler is Test {
    uint256 internal constant WAD = 1e18;

    LendingPool          public pool;
    MockVolatilityOracle public oracle;
    MockERC20            public token;

    // Actors
    address[] public actors;
    address   internal _currentActor;

    // Tracking for invariant checks
    uint256 public totalDeposited;  // sum of all deposit calls
    uint256 public totalWithdrawn;  // sum of all withdraw calls (in asset)
    uint256 public totalBorrowed;
    uint256 public totalRepaid;
    bool    public invalidLiquidationAttempted;

    // Ghost variables
    mapping(address => bool) public hasLiquidatablePosition;

    constructor(LendingPool _pool, MockVolatilityOracle _oracle, MockERC20 _token) {
        pool   = _pool;
        oracle = _oracle;
        token  = _token;

        actors.push(makeAddr("handler_user_0"));
        actors.push(makeAddr("handler_user_1"));
        actors.push(makeAddr("handler_user_2"));

        for (uint256 i = 0; i < actors.length; i++) {
            token.mint(actors[i], 100_000 ether);
            vm.prank(actors[i]);
            token.approve(address(pool), type(uint256).max);
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Bounded Actions
    // ──────────────────────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external {
        _currentActor = actors[actorSeed % actors.length];
        amount = bound(amount, 1 ether, 1_000 ether);

        vm.prank(_currentActor);
        try pool.deposit(amount) {
            totalDeposited += amount;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 sharePct) external {
        _currentActor = actors[actorSeed % actors.length];
        (uint256 shares,,) = pool.users(_currentActor);
        if (shares == 0) return;

        uint256 toWithdraw = bound(sharePct, 1, 100) * shares / 100;
        if (toWithdraw == 0) return;

        uint256 valueEstimate = pool.totalShares() == 0
            ? 0
            : toWithdraw * pool.totalDeposits() / pool.totalShares();

        vm.prank(_currentActor);
        try pool.withdraw(toWithdraw) {
            totalWithdrawn += valueEstimate;
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 pct) external {
        _currentActor = actors[actorSeed % actors.length];
        pct = bound(pct, 1, 95);

        uint256 collateral = pool.depositValue(_currentActor);
        if (collateral == 0) return;

        uint256 maxBorrow = pool.riskManager().getMaxBorrowValue(collateral);
        uint256 existing  = pool.debtOf(_currentActor);
        if (existing >= maxBorrow) return;

        uint256 headroom  = maxBorrow - existing;
        uint256 amount    = (headroom * pct) / 100;
        if (amount == 0) return;

        vm.prank(_currentActor);
        try pool.borrow(amount) {
            totalBorrowed += amount;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 pct) external {
        _currentActor = actors[actorSeed % actors.length];
        uint256 debt = pool.debtOf(_currentActor);
        if (debt == 0) return;

        pct = bound(pct, 1, 100);
        uint256 amount = (debt * pct) / 100;
        if (amount == 0) return;

        // Ensure actor has tokens
        uint256 bal = token.balanceOf(_currentActor);
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        vm.prank(_currentActor);
        try pool.repay(amount) {
            totalRepaid += amount;
        } catch {}
    }

    function setVolatility(uint256 vol) external {
        vol = bound(vol, 0, 0.69e18); // keep below freeze threshold for borrow variety
        oracle.setVolatility(vol);
    }

    function skipTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 30 days);
        skip(seconds_);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant Helpers
    // ──────────────────────────────────────────────────────────────────────────

    function noNegativeBalances() external view returns (bool) {
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 deposits = pool.depositValue(actors[i]);
            // Token balances can't go negative in Solidity, but we check pool accounting
            if (deposits > pool.totalDeposits()) return false;
        }
        return true;
    }

    function allActorsListed() external view returns (address[] memory) {
        return actors;
    }
}
