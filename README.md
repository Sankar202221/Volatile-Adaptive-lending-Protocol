What is VALP?
Most lending protocols set their risk parameters once and pray the market cooperates. VALP doesn't.
Every parameter — LTV, liquidation threshold, liquidation penalty, borrow rate — is a live function of on-chain volatility. When markets go sideways, VALP tightens. When volatility calms down, it opens back up. No governance votes. No manual intervention. No cascades.

How it compares
Common ProtocolsVALPInterest rateStatic slope3-slope + volatility premiumLTVFixed (e.g. 75%)Dynamic f(volatility)Liquidation thresholdFixedDynamic f(volatility)Liquidation bonusFixedGrows with volatilityCircuit breakerNone / manualAuto-freezes at 70% volPrice oracleSpot priceTWAP + rolling std-dev + manipulation guardsTest coverageUnit onlyUnit + Fuzz + 10 Invariants

Architecture
User → LendingPool
            │
   ┌────────┴──────────┐
   │                   │
RiskManager      InterestRateModel
   │                   │
VolatilityOracle ◄─────┘
   │
 (price feed / Chainlink adapter)
Contracts
ContractRoleLendingPool.solEntry point: deposit, borrow, repay, withdrawVolatilityOracle.solRolling-window std-dev volatility + TWAP accumulatorInterestRateModel.solThree-slope rate model with volatility premiumRiskManager.solDynamic LTV, health factor, liquidation threshold + penaltyLiquidationEngine.solLiquidation flow with close factor and dynamic bonus

Core Formulas
Borrow Rate
rate = BASE(2%) + SLOPE_1(10%) × util               [below 80% kink]
     + SLOPE_2(80%) × max(util − 80%, 0)            [above kink]
     + VOL_MULTIPLIER(50%) × volatility

Bounded: [1%, 200%] APR
Adaptive LTV
LTV = 80% − 60% × volatility      (floor: 20%)
Adaptive Liquidation Threshold
LiqThreshold = 85% − 50% × volatility    (floor: 25%)
Liquidation Penalty
Penalty = 5% + 10% × volatility          (cap: 25%)
Health Factor
HF = collateralValue × liquidationThreshold / debtValue
     Position is safe iff HF ≥ 1.0
Circuit Breaker
New borrows are frozen when volatility ≥ 70%.

Volatility Oracle
Ring Buffer
Stores the last 12 (price, timestamp) snapshots in a circular array. Every recordPrice() call advances a monotonically-increasing cumulative price-time product — identical in construction to Uniswap v2's price0CumulativeLast.
Manipulation Resistance
GuardMechanismRate limit≥ 5 s must elapse between snapshotsTWAP anchorIncoming price validated against TWAP, not last tickMax deviationPrice cannot move > 20% from TWAP per updateAccess controlOnly owner or whitelisted feeder can push pricesStaleness checkReads revert if newest snapshot is > 1 h old
Public API
FunctionReturnsrecordPrice(uint256 price)Records snapshot, advances TWAP accumulatorgetTWAP()Time-Weighted Average Price over the full windowgetVolatility()Annualised volatility as a WAD fraction (0–1e18)latestPrice()Most-recently recorded spot price

Why TWAP Makes VALP Manipulation-Resistant
The Attack Vectors
Without TWAP, a lending protocol that trusts spot price is trivially exploitable:

Inflate attack — Push collateral price up via flash loan → borrow more than real collateral supports → price reverts → position instantly insolvent.
Suppress attack — Push collateral price down → trigger spurious liquidations → buy discounted collateral → price reverts → profit.

VALP's Defence
cumulativePrice += prevPrice × (block.timestamp − prevTimestamp)

TWAP = (C_newest − C_oldest) / (T_newest − T_oldest)
With TWAP as the deviation anchor (not the last tick):
|newPrice − TWAP| / TWAP ≤ 20%
Moving the TWAP by 20% requires maintaining a 20%-above-TWAP price for the entire observation window — expensive, capital-intensive, and detectable by any monitoring bot.
Attack Scenarios
ScenarioSpot priceTWAPVALP outcomeFlash-loan spike (1 block)+300% for 1 blockBarely movesrecordPrice() reverts — spike never enters ring bufferSustained multi-block manipulationHolds manipulated priceMoves slowlyEach step is rate-limited AND bounded to 20% per tick vs TWAPOracle feeder goes offlineFrozenFrozenStaleData revert after 1 hLegitimate high vol (ETH crash)Rapid successive movesSmoothly tracksVolatility rises → LTV tightens → rates spike → borrows freeze at 70%
How it Flows Through the System
High vol market
  → TWAP moves slowly, getVolatility() sees elevated std-dev
  → LTV compresses      (e.g. 80% → 32% at 80% vol)
  → LiquidationThreshold drops
  → LiquidationPenalty rises  (incentivises faster liquidators)
  → New borrows frozen at 70% vol
  → Rate spikes         (less attractive to borrow further)
Each adjustment happens gradually through the smoothed TWAP signal — no sudden discontinuities, no liquidation cascades.

Test Suite
test/
├── BaseTest.sol                  — shared fixtures
├── Unit/
│   ├── LendingPool.t.sol
│   ├── RiskAndRateModel.t.sol
│   └── VolatilityOracle.t.sol
├── Fuzz/
│   └── FuzzTests.t.sol           — 1,000+ random inputs per property
└── Invariant/
    ├── Handler.sol               — random action simulator
    └── InvariantTests.t.sol      — 10 protocol invariants
Invariants
#Invariant1Pool token balance ≥ totalDeposits − totalBorrows2totalDeposits ≥ totalBorrows at all times3Global borrow index is monotonically non-decreasing4MIN_LTV ≤ LTV ≤ BASE_LTV for any volatility5Borrow rate within [MIN_RATE, MAX_RATE]6No actor's deposit value exceeds pool total7Sum of individual deposits ≤ totalDeposits8Liquidation penalty within [BASE_PEN, MAX_PEN]9Utilisation never exceeds 100%10Sum of individual shares equals totalShares

Quick Start
bash# Install Foundry
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
forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast

Roadmap

 TWAP-based volatility oracle (manipulation-resistant)
 Three-slope interest rate model with volatility premium
 Dynamic LTV + liquidation threshold + penalty
 Auto circuit breaker at 70% volatility
 Unit + Fuzz + Invariant test suite
 Multi-asset support (asset registry pattern)
 EIP-4626 share vault for deposits
 Dutch auction liquidation engine
 Chainlink oracle adapter
 Backtesting script with historical ETH prices
 Interest rate governance (timelock-guarded params)



Built for real-world DeFi conditions — not ideal ones.
