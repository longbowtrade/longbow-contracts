// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {LongbowExecutor} from "../src/LongbowExecutor.sol";

/// @notice Deploys LongbowExecutor against a real router.
///
/// Usage (mainnet, real Uniswap V2 Router02):
///   ROUTER=0x89e5db8b5aa49aa85ac63f691524311aeb649eba \
///   SEQUENCER_FEED=0x0000000000000000000000000000000000000000 \
///   forge script script/Deploy.s.sol --rpc-url robinhood_mainnet --broadcast \
///     --private-key $DEPLOYER_KEY
contract Deploy is Script {
    function run() external {
        address routerAddr = vm.envAddress("ROUTER");
        address seqFeed = vm.envOr("SEQUENCER_FEED", address(0));
        uint256 maxPriceAge = vm.envOr("MAX_PRICE_AGE", uint256(1 hours));

        vm.startBroadcast();
        LongbowExecutor executor = new LongbowExecutor(routerAddr, seqFeed, maxPriceAge);
        vm.stopBroadcast();

        console2.log("LongbowExecutor:", address(executor));
        console2.log("  router:", routerAddr);
        console2.log("  sequencerFeed:", seqFeed);
        console2.log("  maxPriceAge:", maxPriceAge);
    }
}
