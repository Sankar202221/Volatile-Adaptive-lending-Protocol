// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20}            from "../../src/mocks/MockERC20.sol";
import {MockVolatilityOracle} from "../../src/mocks/MockVolatilityOracle.sol";
import {VolatilityOracle}     from "../../src/VolatilityOracle.sol";
import {InterestRateModel}    from "../../src/InterestRateModel.sol";
import {RiskManager}          from "../../src/RiskManager.sol";
import {LendingPool}          from "../../src/LendingPool.sol";

abstract contract BaseTest is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20            internal token;
    MockVolatilityOracle internal oracle;
    InterestRateModel    internal rateModel;
    RiskManager          internal riskManager;
    LendingPool          internal pool;

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        token       = new MockERC20("USD Coin", "USDC");
        oracle      = new MockVolatilityOracle();
        rateModel   = new InterestRateModel();

        // Deploy RiskManager with a placeholder pool address first,
        // then deploy pool pointing at the real RiskManager.
        // (avoids circular constructor dependency by using a two-step init)
        riskManager = new RiskManager(address(oracle), address(this)); // pool = this (override later)
        pool = new LendingPool(
            address(token),
            address(riskManager),
            address(rateModel),
            address(oracle)
        );

        // Fund users
        token.mint(alice, 10_000 ether);
        token.mint(bob,   10_000 ether);
        token.mint(carol, 10_000 ether);

        // Approvals
        vm.prank(alice); token.approve(address(pool), type(uint256).max);
        vm.prank(bob);   token.approve(address(pool), type(uint256).max);
        vm.prank(carol); token.approve(address(pool), type(uint256).max);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        pool.deposit(amount);
    }

    function _borrow(address user, uint256 amount) internal {
        vm.prank(user);
        pool.borrow(amount);
    }

    function _repay(address user, uint256 amount) internal {
        vm.prank(user);
        pool.repay(amount);
    }

    function _setVol(uint256 vol) internal {
        oracle.setVolatility(vol);
    }

    /// @dev Fast-forward time by `delta` seconds.
    function _skip(uint256 delta) internal {
        skip(delta);
    }
}
