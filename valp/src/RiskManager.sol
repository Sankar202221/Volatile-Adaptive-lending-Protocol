// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VolatilityOracle} from "./VolatilityOracle.sol";

/// @title RiskManager
/// @notice Computes position health and dynamic risk parameters.
///
///   LTV(vol)                  = BASE_LTV  - K_LTV  * vol
///   LiquidationThreshold(vol) = BASE_LIQ  - K_LIQ  * vol
///   LiqPenalty(vol)           = BASE_PEN  + K_PEN  * vol
///
///   HealthFactor = collateralValue * liqThreshold / debtValue
///   Position is safe when HF >= 1e18 (WAD).
///
///   All values WAD-scaled.
contract RiskManager {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant WAD = 1e18;

    // LTV parameters
    uint256 public constant BASE_LTV  = 0.80e18;   // 80% at zero vol
    uint256 public constant K_LTV     = 0.60e18;   // sensitivity: 60% reduction at vol=1
    uint256 public constant MIN_LTV   = 0.20e18;   // floor

    // Liquidation threshold parameters
    uint256 public constant BASE_LIQ  = 0.85e18;   // 85% at zero vol
    uint256 public constant K_LIQ     = 0.50e18;   // sensitivity
    uint256 public constant MIN_LIQ   = 0.25e18;   // floor

    // Liquidation penalty parameters (bonus to liquidator)
    uint256 public constant BASE_PEN  = 0.05e18;   // 5% base bonus
    uint256 public constant K_PEN     = 0.10e18;   // +10% at vol=1
    uint256 public constant MAX_PEN   = 0.25e18;   // 25% ceiling

    // Liquidation threshold: HF must be below this to be liquidatable
    uint256 public constant LIQUIDATION_HF = 1e18;

    // Circuit breaker: if vol exceeds this, new borrows are frozen
    uint256 public constant FREEZE_VOL_THRESHOLD = 0.70e18; // 70%

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    VolatilityOracle public immutable oracle;
    address          public immutable pool;   // only LendingPool calls mutating fns

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error OnlyPool();
    error InsufficientOracleData();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _oracle, address _pool) {
        oracle = VolatilityOracle(_oracle);
        pool   = _pool;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dynamic Parameters
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Current LTV given oracle volatility.
    function getLTV() external view returns (uint256) {
        return _computeLTV(_safeVolatility());
    }

    /// @notice Current liquidation threshold given oracle volatility.
    function getLiquidationThreshold() external view returns (uint256) {
        return _computeLiqThreshold(_safeVolatility());
    }

    /// @notice Current liquidation penalty (bonus) given oracle volatility.
    function getLiquidationPenalty() external view returns (uint256) {
        return _computeLiqPenalty(_safeVolatility());
    }

    /// @notice Whether new borrowing should be frozen (extreme volatility).
    function isBorrowingFrozen() external view returns (bool) {
        try oracle.getVolatility() returns (uint256 v) {
            return v >= FREEZE_VOL_THRESHOLD;
        } catch {
            return true;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Position Analysis
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Max borrowable value for a given collateral value.
    /// @param collateralValue  In any common unit (e.g. USD, 1e18-scaled).
    function getMaxBorrowValue(uint256 collateralValue) external view returns (uint256) {
        return (collateralValue * _computeLTV(_safeVolatility())) / WAD;
    }

    /// @notice Health factor of a position.
    /// @param collateralValue  Current collateral marked-to-market.
    /// @param debtValue        Current outstanding debt.
    /// @return hf  Health factor [0, ∞), WAD-scaled. >= 1e18 is safe.
    function getHealthFactor(uint256 collateralValue, uint256 debtValue)
        external
        view
        returns (uint256 hf)
    {
        if (debtValue == 0) return type(uint256).max;
        uint256 vol      = _safeVolatility();
        uint256 liqThresh = _computeLiqThreshold(vol);
        hf = (collateralValue * liqThresh) / (debtValue);
        // Note: both collateralValue and liqThresh are WAD-scaled so result is correct
    }

    /// @notice Whether a position is liquidatable.
    function isLiquidatable(uint256 collateralValue, uint256 debtValue)
        external
        view
        returns (bool)
    {
        if (debtValue == 0) return false;
        uint256 liqThresh = _computeLiqThreshold(_safeVolatility());
        uint256 hf = (collateralValue * liqThresh) / debtValue;
        return hf < LIQUIDATION_HF;
    }

    /// @notice How much collateral a liquidator receives for repaying `debtToRepay`.
    function getLiquidationReturn(uint256 debtToRepay)
        external
        view
        returns (uint256 collateralReceived)
    {
        uint256 penalty = _computeLiqPenalty(_safeVolatility());
        collateralReceived = (debtToRepay * (WAD + penalty)) / WAD;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    function _safeVolatility() internal view returns (uint256 vol) {
        try oracle.getVolatility() returns (uint256 v) {
            vol = v;
        } catch {
            // Oracle unavailable or stale → assume maximum volatility (fail closed).
            // This tightens LTV, raises the liquidation threshold, and is consistent
            // with isBorrowingFrozen() which also returns true on oracle failure.
            vol = WAD;
        }
    }

    function _computeLTV(uint256 vol) internal pure returns (uint256) {
        uint256 reduction = (K_LTV * vol) / WAD;
        if (reduction >= BASE_LTV - MIN_LTV) return MIN_LTV;
        return BASE_LTV - reduction;
    }

    function _computeLiqThreshold(uint256 vol) internal pure returns (uint256) {
        uint256 reduction = (K_LIQ * vol) / WAD;
        if (reduction >= BASE_LIQ - MIN_LIQ) return MIN_LIQ;
        return BASE_LIQ - reduction;
    }

    function _computeLiqPenalty(uint256 vol) internal pure returns (uint256) {
        uint256 bonus = BASE_PEN + (K_PEN * vol) / WAD;
        if (bonus > MAX_PEN) return MAX_PEN;
        return bonus;
    }
}
