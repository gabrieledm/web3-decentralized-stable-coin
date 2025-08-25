// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DecentralizedStableCoinDeploy is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (address weth_usd_PriceFeed, address wbtc_usd_PriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();

        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [weth_usd_PriceFeed, wbtc_usd_PriceFeed];

        vm.startBroadcast(deployerKey);

        DecentralizedStableCoin stableCoin = new DecentralizedStableCoin();
        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(stableCoin));

        stableCoin.transferOwnership(address(engine));

        vm.stopBroadcast();

        return (stableCoin, engine, helperConfig);
    }
}
