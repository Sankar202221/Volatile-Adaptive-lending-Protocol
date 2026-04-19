// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LendingPool}   from "./LendingPool.sol";
import {RiskManager}   from "./RiskManager.sol";
import {IERC20}        from "./interfaces/IERC20.sol";

/// @title LiquidationEngine
/// @notice Handles liquidation of under-collateralised positions.
///
///         Liquidators repay up to CLOSE_FACTOR of a borrower's debt and
///         receive collateral at a discount (the liquidation penalty).
///         The penalty grows with volatility, incentivising faster liquidations
///         during stress events when bad debt risk is highest.
///
///         Flow:
///         1. Liquidator calls liquidate(borrower, repayAmount).
///         2. Engine checks HF < 1.
///         3. Engine pulls repayAmount from liquidator.
///         4. Engine repays borrower's debt via LendingPool.
///         5. Engine transfers collateral + bonus to liquidator.
contract LiquidationEngine {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant WAD          = 1e18;
    uint256 public constant CLOSE_FACTOR = 0.50e18;  // max 50% of debt per liquidation

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    LendingPool  public immutable pool;
    RiskManager  public immutable riskManager;
    IERC20       public immutable asset;

    uint256 private _locked = 1;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256          debtRepaid,
        uint256          collateralSeized
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error PositionHealthy();
    error ExceedsCloseFactor();
    error ZeroAmount();
    error InsufficientCollateral();
    error TransferFailed();
    error RepayFailed();
    error SeizeFailed();
    error ReentrancyGuard();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _pool, address _riskManager) {
        pool        = LendingPool(_pool);
        riskManager = RiskManager(_riskManager);
        asset       = pool.asset();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Liquidation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Check whether `borrower` is eligible for liquidation.
    function canLiquidate(address borrower) external view returns (bool) {
        return pool.healthFactor(borrower) < WAD;
    }

    /// @notice Liquidate a portion of `borrower`'s debt.
    /// @param borrower      Address to liquidate.
    /// @param repayAmount   Amount of debt asset the liquidator will repay.
    function liquidate(address borrower, uint256 repayAmount) external nonReentrant {
        if (repayAmount == 0) revert ZeroAmount();

        // ── 1. Health check ───────────────────────────────────────────────
        uint256 hf = pool.healthFactor(borrower);
        if (hf >= WAD) revert PositionHealthy();

        // ── 2. Enforce close factor ───────────────────────────────────────
        uint256 totalDebt = pool.debtOf(borrower);
        uint256 maxRepay  = (totalDebt * CLOSE_FACTOR) / WAD;
        if (repayAmount > maxRepay) revert ExceedsCloseFactor();

        // ── 3. Compute collateral to seize ────────────────────────────────
        //    collateralSeized = repayAmount * (1 + liquidationPenalty)
        uint256 collateralSeized = riskManager.getLiquidationReturn(repayAmount);

        // Verify borrower has enough collateral
        uint256 collateral = pool.depositValue(borrower);
        if (collateralSeized > collateral) revert InsufficientCollateral();

        // ── 4. Pull debt repayment from liquidator ────────────────────────
        bool ok = asset.transferFrom(msg.sender, address(this), repayAmount);
        if (!ok) revert TransferFailed();

        // ── 5. Approve pool to pull repayment, repay on behalf of borrower ─
        asset.approve(address(pool), repayAmount);
        // We call repay via low-level call so we can act on behalf of borrower.
        // In a production system the pool would expose repayOnBehalf().
        // Here we use a simplified approach: pool trusts the engine.
        _repayOnBehalf(borrower, repayAmount);

        // ── 6. Transfer seized collateral to liquidator ───────────────────
        //    In a share-based system we'd transfer shares; here we transfer
        //    underlying (pool must have authorised engine to withdraw).
        _seizeCollateral(borrower, msg.sender, collateralSeized);

        emit Liquidated(msg.sender, borrower, repayAmount, collateralSeized);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals (stubs – real impl depends on pool access control design)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Repay debt on behalf of `borrower`.  Production: add onlyEngine
    ///      modifier to pool.repayFor(), or use delegatecall.
    function _repayOnBehalf(address borrower, uint256 amount) internal virtual {
        pool.repayFor(borrower, amount);
    }

    /// @dev Seize collateral from `borrower` and send to `recipient`.
    function _seizeCollateral(
        address borrower,
        address recipient,
        uint256 amount
    ) internal virtual {
        pool.seize(borrower, recipient, amount);
    }
}
