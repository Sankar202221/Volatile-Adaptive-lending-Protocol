// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VolatilityOracle
/// @notice Computes on-chain short-term volatility from price snapshots AND a
///         Time-Weighted Average Price (TWAP) from the same ring buffer.
///
///         ─── Design overview ───────────────────────────────────────────────
///
///         1. RING BUFFER  — stores the last WINDOW_SIZE (price, timestamp)
///            pairs in a circular array.  Oldest slot is overwritten once the
///            buffer is full.
///
///         2. TWAP ACCUMULATOR  — every recordPrice() call appends
///               ΔcumulativePrice += prevPrice × Δt
///            to a monotonically-increasing cumulative and records the snapshot
///            timestamp.  getTWAP() then reads two boundary snapshots and
///            returns the geometric mean price over that interval, identical to
///            the Uniswap v2/v3 TWAP construction.
///
///         3. MANIPULATION RESISTANCE
///            a) Minimum time delta enforced between snapshots.
///            b) Each incoming price is compared against the current TWAP
///               (not just the previous tick).  A flash-loan spike in a single
///               block cannot push a spot price far from its TWAP anchor
///               without accumulating many consecutive updates — which is
///               rate-limited by MIN_UPDATE_INTERVAL.
///            c) MAX_DEVIATION_BPS cap applied relative to TWAP (once TWAP is
///               available) or relative to the previous tick (bootstrapping).
///            d) Caller-restricted recording (owner or whitelisted feeder).
///            e) Staleness guard: if the feeder goes offline, reads revert so
///               callers cannot silently consume stale (low-volatility) data.

contract VolatilityOracle {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant WAD = 1e18;

    /// @notice Number of price snapshots in the rolling window.
    uint256 public constant WINDOW_SIZE = 12;

    /// @notice Minimum wall-clock seconds between successive recordPrice() calls.
    /// @dev    Prevents high-frequency manipulation within a single block or
    ///         between consecutive blocks.
    uint256 public constant MIN_UPDATE_INTERVAL = 5;

    /// @notice Maximum allowed deviation of the incoming price from the
    ///         TWAP anchor, expressed in basis-points (10 000 = 100 %).
    /// @dev    Once two snapshots exist the TWAP is used as the anchor.
    ///         During bootstrap the previous tick is used instead.
    uint256 public constant MAX_DEVIATION_BPS = 2000; // 20 %

    /// @notice Maximum age of the newest snapshot before reads are rejected.
    uint256 public constant STALENESS_THRESHOLD = 1 hours;

    /// @notice Minimum number of snapshots required before getTWAP() is usable.
    uint256 public constant TWAP_MIN_SNAPSHOTS = 2;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    struct PricePoint {
        uint128 price;          // scaled 1e18
        uint64  timestamp;
        // 64 bits padding — slot is 256 bits total (fits in one slot)
    }

    /// @notice Ring buffer of price snapshots.
    PricePoint[WINDOW_SIZE] public history;

    /// @notice Index of the *next* write position in the ring buffer.
    uint256 public head;

    /// @notice Number of valid entries currently in the ring buffer (0 → WINDOW_SIZE).
    uint256 public count;

    // ── TWAP accumulator ─────────────────────────────────────────────────────

    /// @notice Monotonically-increasing cumulative: Σ price[i] × Δt[i].
    ///         Stored as a uint256; cannot realistically overflow on any
    ///         human timescale (would require price ≈ 1e18 held for 1e50 seconds).
    uint256 public cumulativePrice;

    /// @notice Timestamp at which cumulativePrice was last updated.
    uint256 public cumulativeTimestamp;

    /// @dev    Per-snapshot cumulative values stored in a parallel ring buffer
    ///         so that getTWAP() can reconstruct the TWAP for any sub-window
    ///         without iterating every slot.
    uint256[WINDOW_SIZE] internal _cumulativeAtSnapshot;

    // ── Admin ────────────────────────────────────────────────────────────────

    address public owner;
    address public feeder;          // authorised price pusher (e.g. Chainlink adapter)
    address public pendingFeeder;
    uint256 public feederUpdateTime;

    /// @notice Timestamp of the most-recent recordPrice() call.
    uint256 public lastUpdateTimestamp;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event PriceRecorded(uint256 price, uint256 timestamp, uint256 cumulativePrice);
    event FeederUpdated(address indexed feeder);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error Unauthorized();
    error TooFrequent();
    error PriceDeviationTooHigh();   // price too far from TWAP anchor
    error InsufficientData();
    error PriceTooLarge();
    error FeederNotReady();
    error StaleData();               // newest snapshot older than STALENESS_THRESHOLD

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _feeder) {
        owner  = msg.sender;
        feeder = _feeder;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyAuthorized() {
        if (msg.sender != owner && msg.sender != feeder) revert Unauthorized();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Price Ingestion
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Record a new price snapshot and advance the TWAP accumulator.
    /// @param  price  Current asset price, scaled to 1e18.
    ///
    /// @dev    Security flow
    ///         ① Rate-limit: block if < MIN_UPDATE_INTERVAL seconds since last push.
    ///         ② Anchor selection: if TWAP has enough data, use TWAP as anchor;
    ///            otherwise fall back to the previous tick.
    ///         ③ Deviation check: |newPrice − anchor| / anchor ≤ MAX_DEVIATION_BPS.
    ///         ④ Cumulative update: cumulativePrice += prevPrice × (now − prevTime).
    ///         ⑤ Write snapshot.
    function recordPrice(uint256 price) external onlyAuthorized {
        if (price > type(uint128).max) revert PriceTooLarge();

        uint256 n = count;

        if (n > 0) {
            uint256 prevIdx   = (head + WINDOW_SIZE - 1) % WINDOW_SIZE;
            uint64  prevTime  = history[prevIdx].timestamp;
            uint128 prevPrice = history[prevIdx].price;

            // ① Rate-limit
            if (block.timestamp - uint256(prevTime) < MIN_UPDATE_INTERVAL) revert TooFrequent();

            // ② Anchor: prefer TWAP once it is available, else use prev tick
            uint256 anchor;
            if (n >= TWAP_MIN_SNAPSHOTS) {
                // _currentTWAP() is the accumulator-based TWAP over the full
                // populated window — this is the manipulation-resistant anchor.
                anchor = _currentTWAP(n);
            } else {
                anchor = uint256(prevPrice);
            }

            // ③ Deviation check against TWAP anchor
            uint256 diff = price > anchor ? price - anchor : anchor - price;
            if (diff * 10_000 > anchor * MAX_DEVIATION_BPS) revert PriceDeviationTooHigh();

            // ④ Advance cumulative: weight previous price by its time-duration
            uint256 elapsed = block.timestamp - uint256(prevTime);
            cumulativePrice     += uint256(prevPrice) * elapsed;
            cumulativeTimestamp  = block.timestamp;
        } else {
            // Very first data point — initialise timestamp only.
            cumulativeTimestamp = block.timestamp;
        }

        // ⑤ Snapshot the current cumulative alongside the price point so
        //    getTWAP() can reference any two boundary snapshots.
        _cumulativeAtSnapshot[head] = cumulativePrice;

        history[head] = PricePoint({
            price:     uint128(price),
            timestamp: uint64(block.timestamp)
        });

        head = (head + 1) % WINDOW_SIZE;
        if (n < WINDOW_SIZE) count = n + 1;
        lastUpdateTimestamp = block.timestamp;

        emit PriceRecorded(price, block.timestamp, cumulativePrice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TWAP
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the Time-Weighted Average Price over all populated
    ///         snapshots in the ring buffer.
    ///
    /// @dev    Computation
    ///         TWAP = (C_newest − C_oldest) / (T_newest − T_oldest)
    ///         where C is the cumulative price-time product.
    ///
    ///         This is exactly the Uniswap v2 TWAP formula, applied to our
    ///         ring buffer instead of a block-based accumulator.
    ///
    /// @return twap  Time-weighted average price, scaled 1e18.
    function getTWAP() external view returns (uint256 twap) {
        _assertNotStale();
        uint256 n = count;
        if (n < TWAP_MIN_SNAPSHOTS) revert InsufficientData();
        twap = _currentTWAP(n);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Volatility Computation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns annualised volatility as a WAD fraction.
    ///         Uses population std-dev of log-returns (approximated as
    ///         arithmetic returns) over the window.
    /// @return vol  Volatility [0, WAD].  Example: 0.3e18 = 30%.
    function getVolatility() external view returns (uint256 vol) {
        _assertNotStale();
        uint256 n = count;
        if (n < 2) revert InsufficientData();

        // Collect prices in chronological order
        uint256[] memory prices = _orderedPrices(n);

        // Compute returns r[i] = (p[i] - p[i-1]) / p[i-1], scaled by WAD
        uint256 returnCount = n - 1;
        int256[] memory returns_ = new int256[](returnCount);
        int256 sum = 0;

        for (uint256 i = 0; i < returnCount; ) {
            int256 ret = (int256(prices[i + 1]) - int256(prices[i])) * int256(WAD)
                         / int256(prices[i]);
            returns_[i] = ret;
            sum += ret;
            unchecked { ++i; }
        }

        // Mean return
        int256 mean = sum / int256(returnCount);

        // Variance = E[(r − mean)²]
        uint256 variance = 0;
        for (uint256 i = 0; i < returnCount; ) {
            int256 diff     = returns_[i] - mean;
            int256 diffGwei = diff / 1e9;            // scale down to avoid overflow
            variance += uint256(diffGwei * diffGwei);
            unchecked { ++i; }
        }
        variance /= returnCount;

        // Std dev (Babylonian sqrt), then restore scale
        vol = _sqrt(variance) * 1e9;

        // Annualise: ~2 425 846 Ethereum blocks per year → sqrt ≈ 1 557
        vol = vol * 1557;
        if (vol > WAD) vol = WAD;
    }

    /// @notice Returns the latest recorded price.
    function latestPrice() external view returns (uint256) {
        if (count == 0) revert InsufficientData();
        uint256 idx = (head + WINDOW_SIZE - 1) % WINDOW_SIZE;
        return history[idx].price;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setFeeder(address _feeder) external {
        if (msg.sender != owner) revert Unauthorized();
        pendingFeeder    = _feeder;
        feederUpdateTime = block.timestamp + 1 days;
    }

    function applyFeeder() external {
        if (msg.sender != owner) revert Unauthorized();
        if (block.timestamp < feederUpdateTime) revert FeederNotReady();
        feeder = pendingFeeder;
        emit FeederUpdated(feeder);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Reverts with StaleData if the most-recent snapshot is too old.
    ///      Returning stale (low) volatility would silently relax all safety
    ///      parameters — the most dangerous oracle failure mode.
    function _assertNotStale() internal view {
        if (count > 0 && block.timestamp - lastUpdateTimestamp > STALENESS_THRESHOLD) {
            revert StaleData();
        }
    }

    /// @dev Core TWAP computation: (ΔcumulativePrice) / (ΔT) over the n
    ///      populated ring-buffer slots.
    ///
    ///      oldest slot index : (head + WINDOW_SIZE - n) % WINDOW_SIZE
    ///      newest slot index : (head + WINDOW_SIZE - 1) % WINDOW_SIZE
    function _currentTWAP(uint256 n) internal view returns (uint256) {
        uint256 oldestIdx = (head + WINDOW_SIZE - n) % WINDOW_SIZE;
        uint256 newestIdx = (head + WINDOW_SIZE - 1) % WINDOW_SIZE;

        uint256 cOldest = _cumulativeAtSnapshot[oldestIdx];
        uint256 cNewest = _cumulativeAtSnapshot[newestIdx];

        uint64 tOldest = history[oldestIdx].timestamp;
        uint64 tNewest = history[newestIdx].timestamp;

        uint256 deltaT = uint256(tNewest) - uint256(tOldest);
        if (deltaT == 0) {
            // All snapshots share the same timestamp (unlikely but safe fallback).
            return history[newestIdx].price;
        }

        // cNewest − cOldest = Σ price[i] × Δt[i]  (accumulated between the two
        // snapshots).  Dividing by the total elapsed time gives the TWAP.
        return (cNewest - cOldest) / deltaT;
    }

    /// @dev Returns the n populated ring-buffer prices in chronological order.
    function _orderedPrices(uint256 n) internal view returns (uint256[] memory prices) {
        prices = new uint256[](n);
        uint256 start = (head + WINDOW_SIZE - n) % WINDOW_SIZE;
        for (uint256 i = 0; i < n; ) {
            prices[i] = history[(start + i) % WINDOW_SIZE].price;
            unchecked { ++i; }
        }
    }

    /// @dev Babylonian integer square root.
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) >> 1;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
    }
}
