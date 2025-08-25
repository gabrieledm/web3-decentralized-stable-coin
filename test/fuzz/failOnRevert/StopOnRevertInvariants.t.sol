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
import {StopOnRevertHandler} from "./StopOnRevertHandler.t.sol";
import {console} from "forge-std/console.sol";

/**
 * What are our invariants (=the properties of the system we should always hold) ?
 *
 * 1. Total supply of DSC should be less than total value of collateral
 * 2. Getter view functions should never revert
 * 3. Users can't create stablecoins with a bad health factor
 * 4. A user should only be able to be liquidated if he has a bad health factor
 */
contract StopOnRevertInvariants is StdInvariant, Test {
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

    StopOnRevertHandler private handler;

    function setUp() external {
        DecentralizedStableCoinDeploy deployer = new DecentralizedStableCoinDeploy();
        (stableCoin, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        handler = new StopOnRevertHandler(engine, stableCoin);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // Get the value of the debt (DSC) in the protocol
        uint256 totalSupply = stableCoin.totalSupply();

        // Get the value of all the collateral in the protocol
        uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(engine));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUSDValue(weth, wethDeposted);
        uint256 wbtcValue = engine.getUSDValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);

        // The sum of all deposited collateral must be greater than the deposited stable coin(=the debt)
        assert(wethValue + wbtcValue >= totalSupply);
    }

    /**
    * @dev Updates the value of __invariant.fail_on_revert__ in __foundry.toml__ for this invariant test file
    */
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_gettersCantRevert() public view {
        engine.getLiquidationBonus();
        engine.getPrecision();
        engine.getAccountInformation(msg.sender);
        engine.getAccountCollateralValue(msg.sender);
        engine.getUSDValue(weth, 1);
        engine.getTokenAmountFromUSD(weth, 1e18);
        engine.getAdditionalFeedPrecision();
        engine.getCollateralBalanceOfUser(msg.sender, weth);
        engine.getCollateralTokens();
        engine.getHealthFactor(msg.sender);
        engine.getLiquidationPrecision();
        engine.getLiquidationThreshold();
        engine.getMinHealthFactor();
    }
}
