// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DecentralizedStableCoinDeploy} from "../../../script/DecentralizedStableCoinDeploy.s.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
//import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ContinueOnRevertHandler} from "./ContinueOnRevertHandler.t.sol";
import {console} from "forge-std/console.sol";

/**
 * What are our invariants (=the properties of the system we should always hold) ?
 *
 * 1. Total supply of DSC should be less than total value of collateral
 * 2. Getter view functions should never revert
 * 3. Users can't create stablecoins with a bad health factor
 * 4. A user should only be able to be liquidated if he has a bad health factor
 */
contract ContinueOnRevertInvariants is StdInvariant, Test {
    DSCEngine private engine;
    DecentralizedStableCoin private stableCoin;
    HelperConfig private helperConfig;

    address private ethUsdPriceFeed;
    address private btcUsdPriceFeed;
    address private weth;
    address private wbtc;

    uint256 private amountCollateral = 10 ether;
    uint256 private amountToMint = 100 ether;

    uint256 private constant STARTING_USER_BALANCE = 10 ether;
    address private constant USER = address(1);
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address private liquidator = makeAddr("LIQUIDATOR");
    uint256 private collateralToCover = 20 ether;

    ContinueOnRevertHandler private handler;

    function setUp() external {
        DecentralizedStableCoinDeploy deployer = new DecentralizedStableCoinDeploy();
        (stableCoin, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        handler = new ContinueOnRevertHandler(engine, stableCoin);
        targetContract(address(handler));
    }

    /**
    * @dev Updates the value of __invariant.fail_on_revert__ in __foundry.toml__ for this invariant test file
    */
    /// forge-config: default.invariant.fail_on_revert = false
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = stableCoin.totalSupply();
        uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(engine));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUSDValue(weth, wethDeposted);
        uint256 wbtcValue = engine.getUSDValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);

        assert(wethValue + wbtcValue >= totalSupply);
    }

    // function invariant_userCantCreateStabelcoinWithPoorHealthFactor() private {}

    /// forge-config: default.invariant.fail_on_revert = false
    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
