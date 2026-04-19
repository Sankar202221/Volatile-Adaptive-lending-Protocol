# Volatility-Adaptive Lending Protocol (VALP)

> A DeFi lending protocol where interest rates, collateral factors, and liquidation thresholds dynamically adjust based on real-time on-chain volatility.

---

## Architecture

```
User → LendingPool
            │
   ┌────────┴──────────┐
   │                   │
RiskManager      InterestRateModel
   │                   │
VolatilityOracle ◄─────┘
   │
 (price feed / Chainlink adapter)
```

### Contracts

| Contract | Role |
|---|---|
| `LendingPool.sol` | Entry point: deposit, borrow, repay, withdraw |
| `VolatilityOracle.sol` | Rolling-window std-dev volatility + TWAP from price snapshots |
| `InterestRateModel.sol` | Three-slope rate model with volatility premium |
| `RiskManager.sol` | Dynamic LTV, health factor, liquidation threshold + penalty |
| `LiquidationEngine.sol` | Liquidation flow with close factor and dynamic bonus |

---

## Core Formulas

### Borrow Rate
```
rate = BASE(2%) + SLOPE_1(10%) × util               [below 80% kink]
     + SLOPE_2(80%) × max(util − 80%, 0)            [above kink]
     + VOL_MULTIPLIER(50%) × volatility
```
Bounded: `[1%, 200%]` APR.

### Adaptive LTV
```
LTV = 80% − 60% × volatility      (floor: 20%)
```

### Adaptive Liquidation Threshold
```
LiqThreshold = 85% − 50% × volatility    (floor: 25%)
```

### Liquidation Penalty
```
Penalty = 5% + 10% × volatility          (cap: 25%)
```

### Health Factor
```
HF = collateralValue × liquidationThreshold / debtValue
     Position is safe iff HF ≥ 1.0
```

### Circuit Breaker
New borrows are **frozen** when `volatility ≥ 70%`.

---

## Volatility Oracle

### Ring Buffer
Stores the last 12 `(price, timestamp)` snapshots in a circular array.
Every `recordPrice()` call also advances a **monotonically-increasing price-time cumulative** (`Σ price[i] × Δt[i]`), mirroring the Uniswap v2/v3 TWAP accumulator design.

### Manipulation Resistance
| Guard | Mechanism |
|---|---|
| **Rate limit** | ≥ 5 s must elapse between snapshots |
| **TWAP anchor** | Incoming price is validated against the TWAP, not the last tick |
| **Max deviation** | Price cannot move > 20 % from the TWAP anchor per update |
| **Access control** | Only owner or whitelisted feeder can push prices |
| **Staleness check** | Reads revert if the newest snapshot is > 1 h old |

### Public API
| Function | Returns |
|---|---|
| `recordPrice(uint256 price)` | Records snapshot, advances TWAP accumulator |
| `getTWAP()` | Time-Weighted Average Price over the full window |
| `getVolatility()` | Annualised volatility as a WAD fraction (0–1e18) |
| `latestPrice()` | Most-recently recorded spot price |

---

## How TWAP Makes VALP More Secure During Volatility

### The Problem: Spot Price Manipulation

During periods of high market volatility — or deliberate attacks — a spot price can be moved dramatically within a single block via flash loans or coordinated trades. A lending protocol that trusts a raw spot price for collateral valuation, LTV computation, or liquidation decisions becomes trivially exploitable:

- **Inflate attack**: Artificially push the collateral asset price up → borrow far more than the real collateral supports → price reverts → position instantly insolvent.
- **Suppress attack**: Push collateral price down → trigger spurious liquidations → buy discounted collateral → price reverts → profit.

### VALP's TWAP Defence Layer

VALP's `VolatilityOracle` keeps a **Uniswap-style cumulative price-time product** updated alongside the ring buffer:

```
cumulativePrice += prevPrice × (block.timestamp − prevTimestamp)
```

`getTWAP()` then recovers the average:

```
TWAP = (C_newest − C_oldest) / (T_newest − T_oldest)
```

This is identical in construction to Uniswap v2 `price0CumulativeLast`, which has been battle-tested as a manipulation-resistant price reference across billions of dollars of DeFi TVL.

### Why TWAP Neutralises Volatility Attacks

| Attack scenario | Spot price behaviour | TWAP behaviour | VALP outcome |
|---|---|---|---|
| Flash-loan price spike in 1 block | +300 % for 1 block | Barely moves | `recordPrice()` reverts (`PriceDeviationTooHigh`) — spike never enters the ring buffer |
| Sustained multi-block manipulation | Manipulator must hold price for many 5-second intervals | Moves slowly | Each individual step is rate-limited AND bounded to 20 % per tick relative to TWAP |
| Oracle feeder goes offline | Last price frozen | TWAP frozen | `StaleData` revert after 1 h — no stale low-volatility reading can inflate LTVs |
| Legitimate high vol (ETH crash) | Rapid successive moves | Smoothly tracks moves | Volatility signal rises → LTV tightens → borrow rates spike → new borrows freeze at 70 % vol |

### TWAP as the Deviation Anchor

Before TWAP was introduced, the deviation guard compared the incoming price to the **last tick**:
```
|newPrice − prevPrice| / prevPrice ≤ 20%
```
An attacker could walk the price up 20 % per tick, requiring only 5 updates (~25 s) to double the recorded price.

With TWAP as the anchor the check becomes:
```
|newPrice − TWAP| / TWAP ≤ 20%
```
Because the TWAP reflects the **time-weighted history** of all previous snapshots, it cannot be moved quickly even if the attacker controls the feeder. Moving the TWAP by 20 % requires maintaining a 20 %-above-TWAP price for a time equal to the entire observation window — a sustained, capital-intensive attack that is expensive on a public chain and detectable by any monitoring bot.

### Interaction With Adaptive Parameters

The TWAP-anchored oracle feeds directly into the risk parameters that respond hardest during volatility:

```
High vol market
  → TWAP moves slowly, getVolatility() sees elevated std-dev
  → LTV compresses  (e.g. 80% → 32% at 80% vol)
  → LiquidationThreshold drops
  → LiquidationPenalty rises (incentivises faster liquidators)
  → New borrows frozen at 70% vol
  → Rate spikes (less attractive to borrow further)
```

Each of these adjustments happens *gradually*, driven by the smoothed TWAP signal, preventing the sudden discontinuities that enable liquidation cascades in fixed-parameter protocols.

---

## Test Suite

```
test/
├── BaseTest.sol            — shared fixtures
├── Unit/
│   ├── LendingPool.t.sol
│   ├── RiskAndRateModel.t.sol
│   └── VolatilityOracle.t.sol
├── Fuzz/
│   └── FuzzTests.t.sol     — 1 000+ random inputs per property
└── Invariant/
    ├── Handler.sol          — random action simulator
    └── InvariantTests.t.sol — 10 protocol invariants
```

### Key Invariants

| # | Invariant |
|---|---|
| 1 | Pool token balance ≥ `totalDeposits − totalBorrows` |
| 2 | `totalDeposits ≥ totalBorrows` at all times |
| 3 | Global borrow index is monotonically non-decreasing |
| 4 | `MIN_LTV ≤ LTV ≤ BASE_LTV` for any volatility |
| 5 | Borrow rate within `[MIN_RATE, MAX_RATE]` |
| 6 | No actor's deposit value exceeds pool total |
| 7 | Sum of individual deposits ≤ `totalDeposits` |
| 8 | Liquidation penalty within `[BASE_PEN, MAX_PEN]` |
| 9 | Utilisation never exceeds 100% |
| 10 | Sum of individual shares equals `totalShares` |

---

## Quick Start

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Run all tests
forge test -vv

# Run with gas reporting
forge test --gas-report

# Run invariant tests only (256 runs × depth 100)
forge test --match-path "test/Invariant/*" -vvv

# Deploy to local anvil
anvil &
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

---

## What Makes This Elite

| Feature | Common Protocols | VALP |
|---|---|---|
| Interest rate | Static slope | 3-slope + volatility premium |
| LTV | Fixed (e.g. 75%) | Dynamic `f(volatility)` |
| Liquidation threshold | Fixed | Dynamic `f(volatility)` |
| Liquidation bonus | Fixed | Grows with volatility |
| Circuit breaker | None / manual | Automatic at 70% vol |
| Testing | Unit only | Unit + Fuzz + 10 Invariants |
| Price oracle | Spot price | TWAP accumulator + rolling std-dev + manipulation guards |

---

## Roadmap

- [x] TWAP-based volatility (manipulation-resistant)
- [ ] Multi-asset support (asset registry pattern)
- [ ] EIP-4626 share vault for deposits
- [ ] Liquidation auction (Dutch auction > instant)
- [ ] Backtesting script with historical ETH prices
- [ ] Chainlink oracle adapter
- [ ] Interest rate governance (timelock-guarded params)
