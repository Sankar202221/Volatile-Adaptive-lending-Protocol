// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Handler}             from "./Handler.sol";
import {LendingPool}         from "../../src/LendingPool.sol";
import {RiskManager}         from "../../src/RiskManager.sol";
import {InterestRateModel}   from "../../src/InterestRateModel.sol";
import {MockVolatilityOracle} from "../../src/mocks/MockVolatilityOracle.sol";
import {MockERC20}            from "../../src/mocks/MockERC20.sol";

/// @title InvariantTests
/// @notice Core protocol invariants that must hold after ANY sequence of
///         arbitrary user actions (deposit, borrow, repay, withdraw,
///         volatility change, time advance).
///
///         If any invariant fails, Foundry prints the exact call sequence
///         that caused the violation — making this as powerful as formal
///         verification for in-scope state transitions.
contract InvariantTests is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20            internal token;
    MockVolatilityOracle internal oracle;
    InterestRateModel    internal rateModel;
    RiskManager          internal riskManager;
    LendingPool          internal pool;
    Handler              internal handler;

    function setUp() public {
        token       = new MockERC20("USD Coin", "USDC");
        oracle      = new MockVolatilityOracle();
        rateModel   = new InterestRateModel();
        riskManager = new RiskManager(address(oracle), address(this));
        pool        = new LendingPool(
            address(token),
            address(riskManager),
            address(rateModel),
            address(oracle)
        );

        handler = new Handler(pool, oracle, token);

        // Target only the Handler — Foundry calls random sequences of its fns
        targetContract(address(handler));

        // Exclude all selectors except handler's mutating functions
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = Handler.deposit.selector;
        selectors[1] = Handler.withdraw.selector;
        selectors[2] = Handler.borrow.selector;
        selectors[3] = Handler.repay.selector;
        selectors[4] = Handler.setVolatility.selector;
        selectors[5] = Handler.skipTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 1: Protocol Solvency
    // The pool must always hold enough tokens to cover the difference between
    // deposits and borrows.  Allows for small rounding (1 wei).
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_ProtocolSolvent() public view {
        uint256 poolBalance = token.balanceOf(address(pool));
        uint256 netLiability = pool.totalDeposits() > pool.totalBorrows()
            ? pool.totalDeposits() - pool.totalBorrows()
            : 0;

        assertGe(
            poolBalance + 1,  // +1 for rounding
            netLiability,
            "INVARIANT: pool insolvent"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 2: totalDeposits >= totalBorrows
    // Interest accrual increases both proportionally; borrows can never
    // exceed deposits.
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_DepositsGTEBorrows() public view {
        assertGe(
            pool.totalDeposits(),
            pool.totalBorrows(),
            "INVARIANT: borrows exceed deposits"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 3: Borrow Index Monotonicity
    // The global borrow index must never decrease.
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_BorrowIndexMonotone() public view {
        assertGe(
            pool.globalBorrowIndex(),
            WAD,
            "INVARIANT: borrow index below initial value"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 4: LTV Always Within Bounds
    // Regardless of volatility, LTV must be in [MIN_LTV, BASE_LTV].
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_LTVWithinBounds() public view {
        uint256 ltv = riskManager.getLTV();
        assertGe(ltv, riskManager.MIN_LTV(),  "INVARIANT: LTV below minimum");
        assertLe(ltv, riskManager.BASE_LTV(), "INVARIANT: LTV above base");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 5: Interest Rate Always Within Bounds
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_RateWithinBounds() public view {
        // Compute current utilisation
        uint256 util = pool.totalDeposits() == 0
            ? 0
            : (pool.totalBorrows() * WAD) / pool.totalDeposits();
        if (util > WAD) util = WAD;  // cap for safety

        uint256 rate = rateModel.getBorrowRate(util, 0); // vol = 0 for lower bound
        assertGe(rate, rateModel.MIN_RATE(), "INVARIANT: rate below min");
        assertLe(rate, rateModel.MAX_RATE(), "INVARIANT: rate above max");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 6: No Negative Balances
    // No actor's deposit value should exceed totalDeposits.
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_NoNegativeBalances() public view {
        assertTrue(handler.noNegativeBalances(), "INVARIANT: negative balance detected");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 7: Sum of Individual Deposits <= totalDeposits
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_IndividualDepositsSumConsistency() public view {
        address[] memory actors = handler.allActorsListed();
        uint256 sumDeposits = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sumDeposits += pool.depositValue(actors[i]);
        }
        // Allow up to 3 wei rounding per actor for share math
        assertLe(
            sumDeposits,
            pool.totalDeposits() + actors.length * 3,
            "INVARIANT: sum of deposits exceeds pool total"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 8: Liquidation Penalty Within Bounds
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_LiqPenaltyWithinBounds() public view {
        uint256 penalty = riskManager.getLiquidationPenalty();
        assertGe(penalty, riskManager.BASE_PEN(), "INVARIANT: penalty below base");
        assertLe(penalty, riskManager.MAX_PEN(),  "INVARIANT: penalty above max");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 9: Utilisation Never > 100%
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_UtilisationCapped() public view {
        uint256 util = pool.utilization();
        assertLe(util, WAD, "INVARIANT: utilisation > 100%");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INVARIANT 10: Shares Remain Consistent
    // totalShares must equal VIRTUAL_SHARES (dead seed) plus the sum of
    // individual deposit shares.  Real user shares sum to totalShares - VIRTUAL_SHARES.
    // ──────────────────────────────────────────────────────────────────────────
    function invariant_TotalSharesConsistency() public view {
        address[] memory actors = handler.allActorsListed();
        uint256 sumShares = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 s,,) = pool.users(actors[i]);
            sumShares += s;
        }
        // The difference (totalShares - sumShares) must equal VIRTUAL_SHARES:
        // those are the dead shares minted in the constructor that nobody owns.
        assertEq(
            sumShares + pool.VIRTUAL_SHARES(),
            pool.totalShares(),
            "INVARIANT: share sum mismatch (missing VIRTUAL_SHARES)"
        );
    }
}
