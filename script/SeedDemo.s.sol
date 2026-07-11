// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {LongbowExecutor} from "../src/LongbowExecutor.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {MockV2Router} from "../src/mocks/MockV2Router.sol";

/// @notice Full demo environment for Robinhood Chain TESTNET (46630), where
///         no official Uniswap V2 deployment/liquidity exists:
///         mock router + mock stock tokens + mock Chainlink feeds + seeded
///         pools + a LongbowExecutor wired to all of it.
///
/// Usage:
///   forge script script/SeedDemo.s.sol --rpc-url robinhood_testnet \
///     --broadcast --private-key $DEPLOYER_KEY
///
/// Copy the printed addresses into packages/shared/src/addresses.ts (46630)
/// and .env (EXECUTOR_ADDRESS), then set USE_MOCKS=false to trade against it.
contract SeedDemo is Script {
    function run() external {
        vm.startBroadcast();

        MockV2Router router = new MockV2Router();

        MockERC20 usdg = new MockERC20("Global Dollar (demo)", "mUSDG", 6);
        MockERC20 tsla = new MockERC20("Tesla Stock Token (demo)", "mTSLA", 18);
        MockERC20 nvda = new MockERC20("NVIDIA Stock Token (demo)", "mNVDA", 18);

        MockAggregatorV3 tslaFeed = new MockAggregatorV3(8, 268e8);
        MockAggregatorV3 nvdaFeed = new MockAggregatorV3(8, 173e8);
        MockAggregatorV3 seqFeed = new MockAggregatorV3(8, 0); // sequencer up
        // backdate startedAt so the executor's grace period already passed
        seqFeed.setStartedAt(block.timestamp - 2 hours);

        // pools: ~$268k TSLA/USDG, ~$173k NVDA/USDG
        usdg.mint(msg.sender, 1_000_000e6);
        tsla.mint(msg.sender, 2_000e18);
        nvda.mint(msg.sender, 2_000e18);
        usdg.approve(address(router), type(uint256).max);
        tsla.approve(address(router), type(uint256).max);
        nvda.approve(address(router), type(uint256).max);
        router.seedLiquidity(address(tsla), address(usdg), 1_000e18, 268_000e6);
        router.seedLiquidity(address(nvda), address(usdg), 1_000e18, 173_000e6);

        LongbowExecutor executor =
            new LongbowExecutor(address(router), address(seqFeed), 1 hours);

        vm.stopBroadcast();

        console2.log("== Longbow demo environment (testnet 46630) ==");
        console2.log("MockV2Router:   ", address(router));
        console2.log("mUSDG (6 dec):  ", address(usdg));
        console2.log("mTSLA:          ", address(tsla));
        console2.log("mNVDA:          ", address(nvda));
        console2.log("TSLA feed:      ", address(tslaFeed));
        console2.log("NVDA feed:      ", address(nvdaFeed));
        console2.log("Sequencer feed: ", address(seqFeed));
        console2.log("LongbowExecutor:", address(executor));
    }
}
