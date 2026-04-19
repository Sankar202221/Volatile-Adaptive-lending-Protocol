// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title InterestRateModel
/// @notice Three-variable rate model:
///
///   rate = BASE_RATE
///        + SLOPE_1 * utilization                          (below kink)
///        + SLOPE_2 * max(utilization - KINK, 0)           (above kink)
///        + VOL_MULTIPLIER * volatility                     (vol premium)
///
///   All values are WAD-scaled (1e18 = 100% APR).
///
///   Security properties:
///   - reserveFactor updates are timelocked (2 days) to protect depositors.
///   - Two-step ownership prevents accidental admin loss.
///   - getBorrowRate caps utilization at WAD instead of reverting so the
///     accrual loop can never be bricked by a transiently over-utilised pool.
contract InterestRateModel {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant WAD              = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    // Rate model parameters (all in WAD)
    uint256 public constant BASE_RATE      = 0.02e18;  // 2% base APR
    uint256 public constant SLOPE_1        = 0.10e18;  // +10% APR at full util below kink
    uint256 public constant SLOPE_2        = 0.80e18;  // +80% APR for util above kink
    uint256 public constant KINK           = 0.80e18;  // 80% utilisation kink
    uint256 public constant VOL_MULTIPLIER = 0.50e18;  // 50% weight on volatility
    uint256 public constant MIN_RATE       = 0.01e18;  // 1%  floor
    uint256 public constant MAX_RATE       = 2.00e18;  // 200% ceiling

    /// @notice Minimum delay between queuing and executing a reserveFactor change.
    ///         Gives depositors time to exit before a governance-level yield drain.
    uint256 public constant TIMELOCK_DELAY = 2 days;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;        // two-step ownership

    uint256 public reserveFactor = 0.10e18; // 10% of interest goes to reserves

    // Timelock for reserveFactor changes
    uint256 public pendingReserveFactor;
    uint256 public reserveFactorUpdateTime; // timestamp after which execute is valid

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ReserveFactorQueued(uint256 pendingFactor, uint256 executeAfter);
    event ReserveFactorUpdated(uint256 newFactor);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error Unauthorized();
    error TimelockActive();
    error NoPendingUpdate();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ownership (two-step)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Step 1: nominate `newOwner` as the pending owner.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2: accept the pending ownership transfer.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Timelocked Reserve Factor
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Queue a reserveFactor change.  Executes after TIMELOCK_DELAY seconds.
    /// @dev    The 2-day window gives depositors notice before yield can be redirected
    ///         to reserves.  Without a timelock the owner could instantly set
    ///         reserveFactor = WAD and drain all depositor yield.
    function queueReserveFactorUpdate(uint256 _newFactor) external {
        if (msg.sender != owner) revert Unauthorized();
        require(_newFactor <= WAD, "Invalid factor");
        pendingReserveFactor    = _newFactor;
        reserveFactorUpdateTime = block.timestamp + TIMELOCK_DELAY;
        emit ReserveFactorQueued(_newFactor, reserveFactorUpdateTime);
    }

    /// @notice Execute a previously queued reserveFactor change after the timelock expires.
    function executeReserveFactorUpdate() external {
        if (msg.sender != owner)             revert Unauthorized();
        if (reserveFactorUpdateTime == 0)    revert NoPendingUpdate();
        if (block.timestamp < reserveFactorUpdateTime) revert TimelockActive();
        reserveFactor           = pendingReserveFactor;
        reserveFactorUpdateTime = 0;
        emit ReserveFactorUpdated(reserveFactor);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Annual borrow rate for given utilisation and volatility.
    /// @param utilization  Pool utilisation [0, WAD].  Values > WAD are capped —
    ///                     callers must not rely on this function reverting for
    ///                     over-utilised pools.
    /// @param volatility   Normalised volatility from VolatilityOracle [0, WAD].
    /// @return annualRate  Borrow APR in WAD.
    function getBorrowRate(uint256 utilization, uint256 volatility)
        public
        pure
        returns (uint256 annualRate)
    {
        // Cap at WAD: an over-utilised pool must still be able to accrue interest.
        // Reverting here would brick the accrual loop and freeze the entire protocol.
        if (utilization > WAD) utilization = WAD;
        require(volatility  <= WAD, "vol  > 1");

        // ── Utilisation component ──────────────────────────────────────────
        uint256 utilComponent;
        if (utilization <= KINK) {
            utilComponent = (SLOPE_1 * utilization) / WAD;
        } else {
            utilComponent = (SLOPE_1 * KINK) / WAD
                          + (SLOPE_2 * (utilization - KINK)) / WAD;
        }

        // ── Volatility premium ─────────────────────────────────────────────
        uint256 volPremium = (VOL_MULTIPLIER * volatility) / WAD;

        // ── Assemble ───────────────────────────────────────────────────────
        annualRate = BASE_RATE + utilComponent + volPremium;

        // ── Bounds ────────────────────────────────────────────────────────
        if (annualRate < MIN_RATE) annualRate = MIN_RATE;
        if (annualRate > MAX_RATE) annualRate = MAX_RATE;
    }

    /// @notice Per-second borrow rate (for accrual).
    function getBorrowRatePerSecond(uint256 utilization, uint256 volatility)
        external
        pure
        returns (uint256)
    {
        uint256 annual = getBorrowRate(utilization, volatility);
        return annual / SECONDS_PER_YEAR;
    }

    /// @notice Supply APY (simplified: rate * utilisation, ignoring compounding).
    function getSupplyRate(uint256 utilization, uint256 volatility)
        external
        view
        returns (uint256)
    {
        uint256 borrow = getBorrowRate(utilization, volatility);
        return (borrow * utilization / WAD) * (WAD - reserveFactor) / WAD;
    }
}
