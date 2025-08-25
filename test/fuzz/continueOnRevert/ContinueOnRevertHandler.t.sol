// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
//import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {DSCEngine, AggregatorV3Interface} from "../../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStableCoin.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {console} from "forge-std/console.sol";

contract ContinueOnRevertHandler is Test {
    // Deployed contracts to interact with
    DSCEngine private engine;
    DecentralizedStableCoin private stableCoin;
    MockV3Aggregator private ethUsdPriceFeed;
    MockV3Aggregator private btcUsdPriceFeed;
    ERC20Mock private weth;
    ERC20Mock private wbtc;

    // Ghost Variables
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        engine = _dscEngine;
        stableCoin = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    // FUNCTIONS TO INTERACT WITH

    ///////////////
    // DSCEngine //
    ///////////////
    /**
     * @dev As for fuzz testing, by passing parameters to the function they are randomized during tests
     */
    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 0, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateral.mint(msg.sender, amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 0, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnDsc(uint256 amountDsc) public {
        amountDsc = bound(amountDsc, 0, stableCoin.balanceOf(msg.sender));
        stableCoin.burn(amountDsc);
    }

    function mintDsc(uint256 amountDsc) public {
        amountDsc = bound(amountDsc, 0, MAX_DEPOSIT_SIZE);
        stableCoin.mint(msg.sender, amountDsc);
    }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        engine.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    /////////////////////////////
    // DecentralizedStableCoin //
    /////////////////////////////
    function transferDsc(uint256 amountDsc, address to) public {
        amountDsc = bound(amountDsc, 0, stableCoin.balanceOf(msg.sender));
        vm.prank(msg.sender);
        stableCoin.transfer(to, amountDsc);
    }

    /////////////////////////////
    // Aggregator //
    /////////////////////////////
    function updateCollateralPrice(/*uint128 newPrice, */uint256 collateralSeed) public {
        //        int256 intNewPrice = int256(uint256(newPrice));
        int256 intNewPrice = 0;
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(intNewPrice);
    }

    /// Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function callSummary() external view {
        console.log("WETH total deposited", weth.balanceOf(address(engine)));
        console.log("WBTC total deposited", wbtc.balanceOf(address(engine)));
        console.log("Total supply of DSC", stableCoin.totalSupply());
    }
}
