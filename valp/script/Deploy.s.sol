// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {VolatilityOracle}  from "../src/VolatilityOracle.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {RiskManager}       from "../src/RiskManager.sol";
import {LendingPool}       from "../src/LendingPool.sol";
import {MockERC20}         from "../src/mocks/MockERC20.sol";

/// @notice Deploy full VALP stack.
///         Usage:
///           forge script script/Deploy.s.sol --rpc-url $RPC_URL \
///             --broadcast --verify --etherscan-api-key $KEY
///
///         Env vars:
///           ASSET_ADDRESS   - existing ERC-20 token (leave unset to deploy mock)
///           PRICE_FEEDER    - address authorised to push prices to the oracle
contract Deploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);
        address feeder     = vm.envOr("PRICE_FEEDER", deployer);
        address assetAddr  = vm.envOr("ASSET_ADDRESS", address(0));

        vm.startBroadcast(deployerPk);

        // ── 1. Asset ──────────────────────────────────────────────────────
        MockERC20 asset;
        if (assetAddr == address(0)) {
            asset = new MockERC20("Mock USDC", "mUSDC");
            console.log("MockERC20 deployed:", address(asset));
            // Mint 1M for deployer to seed the pool
            asset.mint(deployer, 1_000_000 ether);
        }

        // ── 2. VolatilityOracle ───────────────────────────────────────────
        VolatilityOracle oracle = new VolatilityOracle(feeder);
        console.log("VolatilityOracle deployed:", address(oracle));

        // ── 3. InterestRateModel ──────────────────────────────────────────
        InterestRateModel rateModel = new InterestRateModel();
        console.log("InterestRateModel deployed:", address(rateModel));

        // ── 4. RiskManager (placeholder pool — updated after pool deploy) ─
        // We pass address(0) as pool for now; in production, add a setPool()
        RiskManager riskManager = new RiskManager(address(oracle), address(0));
        console.log("RiskManager deployed:", address(riskManager));

        // ── 5. LendingPool ────────────────────────────────────────────────
        address finalAsset = assetAddr != address(0) ? assetAddr : address(asset);
        LendingPool pool = new LendingPool(
            finalAsset,
            address(riskManager),
            address(rateModel),
            address(oracle)
        );
        console.log("LendingPool deployed:", address(pool));

        vm.stopBroadcast();

        // Print summary
        console.log("\n========= VALP DEPLOYMENT SUMMARY =========");
        console.log("Asset:            ", finalAsset);
        console.log("VolatilityOracle: ", address(oracle));
        console.log("InterestRateModel:", address(rateModel));
        console.log("RiskManager:      ", address(riskManager));
        console.log("LendingPool:      ", address(pool));
        console.log("Price Feeder:     ", feeder);
        console.log("============================================\n");
        console.log("NEXT STEPS:");
        console.log("1. Seed initial prices via oracle.recordPrice(<price>)");
        console.log("2. Deposit liquidity via pool.deposit(<amount>)");
        console.log("3. Configure feeder bot to push prices every ~30s");
    }
}
