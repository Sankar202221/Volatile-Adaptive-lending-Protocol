// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RiskManager}      from "./RiskManager.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {VolatilityOracle}  from "./VolatilityOracle.sol";
import {IERC20}            from "./interfaces/IERC20.sol";

/// @title LendingPool
/// @notice Core entry point for the Volatility-Adaptive Lending Protocol (VALP).
///
///         Supports a single collateral/borrow asset pair for clarity.
///         Extend to multi-asset via asset registries.
///
///         Key mechanics:
///         - Deposits earn interest proportional to utilisation + volatility.
///         - Borrows cost dynamic rate based on utilisation + volatility.
///         - LTV and liquidation thresholds shrink under high volatility.
///         - Circuit breaker freezes new borrows at extreme volatility.
///
///         Security properties:
///         - Health check occurs BEFORE state mutation in withdraw().
///         - Oracle failures default to maximum volatility (fail closed).
///         - Interest compounding uses a 3rd-order Taylor approximation.
///         - Virtual share seed guards against first-deposit inflation attack.
///         - Two-step ownership transfer prevents accidental admin loss.
contract LendingPool {
    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    struct UserState {
        uint256 depositShares;  // pool-share tokens representing the deposit
        uint256 scaledDebt;     // normalised debt: principal / globalBorrowIndex at borrow time
        uint128 lastUpdateTime; // seconds (currently unused; reserved for per-user snapshots)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant WAD = 1e18;

    /// @notice Dead shares minted at construction to mitigate the ERC-4626 inflation attack.
    ///         Nobody owns these shares; they keep the initial share price anchored at 1.
    uint256 public constant VIRTUAL_SHARES = 1_000;

    /// @notice Maximum time window accrued in a single _accrueInterest() call.
    ///         Caps index growth on pools that were dormant for a very long time.
    uint256 public constant MAX_ACCRUAL_ELAPSED = 365 days;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    IERC20              public immutable asset;
    RiskManager         public immutable riskManager;
    InterestRateModel   public immutable rateModel;
    VolatilityOracle    public immutable oracle;

    address public owner;
    address public pendingOwner;        // two-step ownership
    address public liquidationEngine;

    // Global pool state
    uint256 public totalDeposits;   // underlying asset units (incl. virtual seed)
    uint256 public totalBorrows;    // underlying asset units (principal + accrued interest)
    uint256 public totalShares;     // deposit shares outstanding (incl. VIRTUAL_SHARES)
    uint256 public globalBorrowIndex = WAD; // cumulative borrow index (starts at 1e18)
    uint256 public reserves;        // accrued protocol fees
    uint256 public lastAccrualTime;

    // Per-user state
    mapping(address => UserState) public users;

    // Simple reentrancy guard
    uint256 private _locked = 1;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed borrower, uint256 amount, uint256 scaledDebtReduced);
    event InterestAccrued(uint256 borrowIndex, uint256 totalBorrows, uint256 timestamp);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error ReentrancyGuard();
    error ZeroAmount();
    error InsufficientLiquidity();
    error ExceedsMaxBorrow();
    error BorrowingFrozen();
    error HealthyPosition();
    error InsufficientShares();
    error TransferFailed();
    error InsufficientCollateral();
    error Unauthorized();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _asset,
        address _riskManager,
        address _rateModel,
        address _oracle
    ) {
        asset        = IERC20(_asset);
        riskManager  = RiskManager(_riskManager);
        rateModel    = InterestRateModel(_rateModel);
        oracle       = VolatilityOracle(_oracle);
        owner        = msg.sender;
        lastAccrualTime = block.timestamp;

        // Seed virtual dead shares — no real tokens are deposited here.
        // The share price starts at 1 : 1 and cannot be inflated before
        // the first real deposit because the attacker's donation is split
        // across VIRTUAL_SHARES + their own deposit.
        totalShares   = VIRTUAL_SHARES;
        totalDeposits = VIRTUAL_SHARES;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setLiquidationEngine(address _engine) external {
        if (msg.sender != owner) revert Unauthorized();
        liquidationEngine = _engine;
    }

    function withdrawReserves(address to, uint256 amount) external nonReentrant accrueInterest {
        if (msg.sender != owner) revert Unauthorized();
        require(amount <= reserves, "Insufficient reserves");
        reserves -= amount;
        _pushTokens(to, amount);
    }

    /// @notice Step 1 of two-step ownership transfer.  Initiates a handoff to `newOwner`.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2 of two-step ownership transfer.  Must be called by `pendingOwner`.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
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

    modifier onlyLiquidationEngine() {
        require(msg.sender == liquidationEngine, "Only engine");
        _;
    }

    modifier accrueInterest() {
        _accrueInterest();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core Actions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit `amount` of asset into the pool.
    /// @dev    Depositing collateral is always allowed, even with an existing borrow.
    ///         This is the primary mechanism for restoring an unhealthy position
    ///         (as in Aave/Compound).  Blocking deposits from indebted users forces
    ///         them into liquidation and increases bad-debt risk for the protocol.
    /// @return shares  Deposit shares minted.
    function deposit(uint256 amount)
        external
        nonReentrant
        accrueInterest
        returns (uint256 shares)
    {
        if (amount == 0) revert ZeroAmount();

        // shares = amount * totalShares / totalDeposits
        // totalDeposits is always >= VIRTUAL_SHARES > 0, so no zero-division.
        shares = (amount * totalShares) / totalDeposits;

        users[msg.sender].depositShares += shares;
        totalShares    += shares;
        totalDeposits  += amount;

        _pullTokens(msg.sender, amount);

        emit Deposited(msg.sender, amount, shares);
    }

    /// @notice Withdraw `shares` worth of asset from the pool.
    ///
    /// @dev    CRITICAL: The health-factor check is performed BEFORE any state
    ///         mutation.  The projected post-withdrawal position is evaluated using
    ///         local variables derived from current state.  Only after the check
    ///         passes do we write to storage.
    ///
    ///         Mutating state first and then reverting is an anti-pattern:
    ///         - It creates a dirty-state window visible to re-entrant paths.
    ///         - It can cause silent accounting holes if a prior call already
    ///           modified the same storage slot in the same transaction.
    ///
    /// @return amount  Underlying tokens returned.
    function withdraw(uint256 shares)
        external
        nonReentrant
        accrueInterest
        returns (uint256 amount)
    {
        if (shares == 0) revert ZeroAmount();
        UserState storage u = users[msg.sender];
        if (u.depositShares < shares) revert InsufficientShares();

        // amount = shares * totalDeposits / totalShares
        amount = (shares * totalDeposits) / totalShares;

        // Ensure liquidity is available
        uint256 available = totalDeposits - totalBorrows;
        if (amount > available) revert InsufficientLiquidity();

        // ── Health check BEFORE state mutation ──────────────────────────────
        // Compute the projected collateral value after the withdrawal and
        // verify the position stays healthy.  We use local variables so
        // storage is never dirtied if the check fails.
        if (u.scaledDebt > 0) {
            uint256 newDepositShares = u.depositShares - shares;
            uint256 newTotalShares   = totalShares     - shares;
            uint256 newTotalDeposits = totalDeposits   - amount;

            uint256 remainingCollateral = newTotalShares == 0
                ? 0
                : (newDepositShares * newTotalDeposits) / newTotalShares;

            uint256 hf = riskManager.getHealthFactor(remainingCollateral, _currentDebt(u));
            if (hf < WAD) revert InsufficientCollateral();
        }

        // ── State mutation (only reached if health check passed) ─────────
        u.depositShares -= shares;
        totalShares     -= shares;
        totalDeposits   -= amount;

        _pushTokens(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, shares);
    }

    /// @notice Borrow `amount` of asset.  Caller must have sufficient collateral.
    ///         In a single-asset pool, deposited balance IS the collateral.
    function borrow(uint256 amount)
        external
        nonReentrant
        accrueInterest
    {
        if (amount == 0)                        revert ZeroAmount();
        if (riskManager.isBorrowingFrozen())    revert BorrowingFrozen();

        UserState storage u = users[msg.sender];

        // Collateral value = user's deposit share redeemable value
        uint256 collateralValue = totalShares == 0
            ? 0
            : (u.depositShares * totalDeposits) / totalShares;

        // Include any existing debt when computing headroom
        uint256 existingDebt = _currentDebt(u);
        uint256 maxBorrow    = riskManager.getMaxBorrowValue(collateralValue);
        if (existingDebt + amount > maxBorrow) revert ExceedsMaxBorrow();

        // Liquidity check
        if (amount > totalDeposits - totalBorrows) revert InsufficientLiquidity();

        // Store principal scaled by current index so interest accrues automatically
        uint256 scaledAmount = (amount * WAD) / globalBorrowIndex;
        u.scaledDebt      += scaledAmount;
        totalBorrows       += amount;

        _pushTokens(msg.sender, amount);

        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay `amount` of the caller's own debt.
    function repay(uint256 amount)
        external
        nonReentrant
        accrueInterest
    {
        _repayInternal(msg.sender, msg.sender, amount);
    }

    /// @notice Repay debt on behalf of `borrower`.
    /// @dev    Tokens are pulled from `msg.sender`; debt is reduced for `borrower`.
    ///         This decouples the liquidation engine from `repayFor()` and allows
    ///         any party (e.g. a keeper, a guardian) to top up a position without
    ///         requiring privileged access.
    function repayOnBehalf(address borrower, uint256 amount)
        external
        nonReentrant
        accrueInterest
    {
        _repayInternal(borrower, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Liquidation Handlers  (onlyLiquidationEngine)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Repay debt for `borrower`.  Tokens pulled from the liquidation engine.
    function repayFor(address borrower, uint256 amount)
        external
        onlyLiquidationEngine
        accrueInterest
    {
        _repayInternal(borrower, msg.sender, amount);
    }

    /// @notice Seize `amount` of underlying from `borrower` and send to `recipient`.
    ///
    /// @dev    CRITICAL: The `totalDeposits` reduction must use the share-derived
    ///         underlying value, NOT the raw `amount` argument.
    ///
    ///         Reason: sharesToSeize is rounded UP (ceiling division) so that dust
    ///         cannot prevent a full seizure.  The ceiling shares map to an underlying
    ///         value that is >= `amount`.  Subtracting `amount` instead of the true
    ///         share value creates an accounting hole where totalDeposits undershoots
    ///         the real balance — eventually violating the solvency invariant.
    function seize(address borrower, address recipient, uint256 amount)
        external
        onlyLiquidationEngine
        accrueInterest
    {
        UserState storage u = users[borrower];

        if (totalDeposits == 0 || totalShares == 0) return;

        // Ceiling division: rounds up so dust doesn't prevent full seizure.
        uint256 sharesToSeize = (amount * totalShares + totalDeposits - 1) / totalDeposits;

        // Cap at what the borrower actually holds
        if (u.depositShares < sharesToSeize) {
            sharesToSeize = u.depositShares;
        }

        // Derive the exact underlying represented by the seized shares.
        // Using this value (not `amount`) ensures totalDeposits tracks reality.
        uint256 actualUnderlying = (sharesToSeize * totalDeposits) / totalShares;

        u.depositShares -= sharesToSeize;
        totalShares     -= sharesToSeize;
        totalDeposits   -= actualUnderlying;

        _pushTokens(recipient, actualUnderlying);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Current utilisation ratio [0, WAD].  Capped at 100%.
    function utilization() external view returns (uint256) {
        if (totalDeposits == 0) return 0;
        uint256 util = (totalBorrows * WAD) / totalDeposits;
        return util > WAD ? WAD : util;
    }

    /// @notice Current annual borrow APR [WAD].
    function currentBorrowRate() external view returns (uint256) {
        uint256 util;
        if (totalDeposits > 0) {
            util = (totalBorrows * WAD) / totalDeposits;
            if (util > WAD) util = WAD;
        }
        uint256 vol = _safeVolatility();
        return rateModel.getBorrowRate(util, vol);
    }

    /// @notice Deposit value redeemable by `user`.
    function depositValue(address user) external view returns (uint256) {
        UserState storage u = users[user];
        if (totalShares == 0) return 0;
        return (u.depositShares * totalDeposits) / totalShares;
    }

    /// @notice Outstanding debt (principal + accrued interest) of `user`.
    function debtOf(address user) external view returns (uint256) {
        return _currentDebt(users[user]);
    }

    /// @notice Health factor of `user` [WAD]. >= 1e18 is safe.
    function healthFactor(address user) external view returns (uint256) {
        UserState storage u = users[user];
        uint256 collateral = totalShares == 0
            ? 0
            : (u.depositShares * totalDeposits) / totalShares;
        uint256 debt = _currentDebt(u);
        return riskManager.getHealthFactor(collateral, debt);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Interest Accrual
    // ─────────────────────────────────────────────────────────────────────────

    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0 || totalBorrows == 0) {
            lastAccrualTime = block.timestamp;
            return;
        }

        // Cap elapsed to prevent runaway compounding on dormant pools.
        if (elapsed > MAX_ACCRUAL_ELAPSED) elapsed = MAX_ACCRUAL_ELAPSED;

        // Utilisation, capped at WAD so getBorrowRate() never reverts.
        uint256 util = totalDeposits == 0
            ? 0
            : (totalBorrows * WAD) / totalDeposits;
        if (util > WAD) util = WAD;

        uint256 vol = _safeVolatility();

        // Per-second rate
        uint256 annualRate = rateModel.getBorrowRate(util, vol);
        uint256 ratePerSec = annualRate / 365.25 days;

        // 3rd-order Taylor approximation of continuous compounding: e^(rt)
        //   e^x ≈ 1 + x + x²/2 + x³/6
        // The 2nd-order version (used previously) underestimates by ~13% at
        // 200% APR / 1-year window.  The cubic term closes most of that gap.
        uint256 rt  = ratePerSec * elapsed;      // WAD-scaled
        uint256 rt2 = (rt  * rt)  / WAD;          // (rt)²  WAD-scaled
        uint256 rt3 = (rt2 * rt)  / WAD;          // (rt)³  WAD-scaled
        uint256 multiplier = WAD + rt + (rt2 / 2) + (rt3 / 6);

        uint256 newTotalBorrows = (totalBorrows * multiplier) / WAD;
        uint256 interest        = newTotalBorrows - totalBorrows;

        uint256 fee       = (interest * rateModel.reserveFactor()) / WAD;
        reserves         += fee;
        totalBorrows      = newTotalBorrows;
        totalDeposits    += (interest - fee); // depositors earn net interest

        // Compound the global borrow index by the same multiplier
        globalBorrowIndex = (globalBorrowIndex * multiplier) / WAD;

        lastAccrualTime = block.timestamp;

        emit InterestAccrued(globalBorrowIndex, totalBorrows, block.timestamp);
    }

    function _currentDebt(UserState storage u) internal view returns (uint256) {
        if (u.scaledDebt == 0) return 0;
        return (u.scaledDebt * globalBorrowIndex) / WAD;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal Repay Logic
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Shared repayment logic.  Tokens pulled from `payer`; debt cleared for `borrower`.
    ///
    ///      ACCOUNTING NOTE (Bug 2 fix):
    ///      totalBorrows is reduced by `(scaledRepay * globalBorrowIndex) / WAD`,
    ///      NOT by `repayAmount`.  The difference matters for partial repayments:
    ///
    ///        scaledRepay = floor(repayAmount * WAD / globalBorrowIndex)
    ///        → scaledRepay * globalBorrowIndex / WAD  <=  repayAmount  (rounding)
    ///
    ///      Subtracting `repayAmount` every time would continuously over-reduce
    ///      totalBorrows, causing it to undercount the true outstanding debt
    ///      and eventually violating the solvency invariant (totalDeposits >= totalBorrows).
    ///
    ///      For a FULL repay we retire the entire scaledDebt rather than dividing,
    ///      ensuring no dust scaled units remain after repayment-in-full.
    function _repayInternal(address borrower, address payer, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        UserState storage u = users[borrower];

        uint256 debt = _currentDebt(u);

        uint256 scaledRepay;
        uint256 repayAmount;

        if (amount >= debt) {
            // Full repay: retire the entire scaled position to avoid dust.
            scaledRepay = u.scaledDebt;
            repayAmount = debt; // pull only the actual debt, not more
        } else {
            scaledRepay = (amount * WAD) / globalBorrowIndex;
            repayAmount = amount;
        }

        u.scaledDebt -= scaledRepay;

        // Reduce totalBorrows by the exact unscaled value of the retired scaled units.
        uint256 totalBorrowsReduction = (scaledRepay * globalBorrowIndex) / WAD;
        if (totalBorrows >= totalBorrowsReduction) {
            totalBorrows -= totalBorrowsReduction;
        } else {
            totalBorrows = 0;
        }

        _pullTokens(payer, repayAmount);

        emit Repaid(borrower, repayAmount, scaledRepay);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Returns current oracle volatility, defaulting to WAD (100% = maximum)
    ///      on any oracle failure.
    ///
    ///      Philosophy: FAIL CLOSED.  Using 0 on failure (the old behaviour) was
    ///      the most dangerous possible default: it maximised LTV, minimised the
    ///      liquidation threshold, and disabled the circuit breaker.  Using WAD
    ///      does the opposite — it tightens all safety parameters and triggers the
    ///      borrowing freeze.  This is consistent with isBorrowingFrozen() returning
    ///      true on oracle failure.
    function _safeVolatility() internal view returns (uint256) {
        try oracle.getVolatility() returns (uint256 v) {
            return v;
        } catch {
            return WAD; // oracle unavailable → assume maximum volatility (fail closed)
        }
    }

    function _pullTokens(address from, uint256 amount) internal {
        bool ok = asset.transferFrom(from, address(this), amount);
        if (!ok) revert TransferFailed();
    }

    function _pushTokens(address to, uint256 amount) internal {
        bool ok = asset.transfer(to, amount);
        if (!ok) revert TransferFailed();
    }
}
