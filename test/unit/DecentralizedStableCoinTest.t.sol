// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DecentralizedStableCoinDeploy} from "../../script/DecentralizedStableCoinDeploy.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DecentralizedStableCoinDeploy private deployer;
    DecentralizedStableCoin private stableCoin;
    DSCEngine private engine;
    HelperConfig private helperConfig;
    address private eth_usd_PriceFeed;
    address private btc_usd_PriceFeed;
    address private weth;

    address public USER = makeAddr("USER");
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant COLLATERAL_TO_REDEEM = 2 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant ZERO = 0;
    address public constant ZERO_ADDRESS = address(0);
    uint256 public constant DSC_TO_MINT = 10 ether;
    uint256 public constant DSC_TO_BURN = 5 ether;
    uint256 public constant DEBT_TO_COVER = 2 ether;

    modifier mintDSC() {
        vm.prank(address(engine));
        stableCoin.mint(USER, DSC_TO_MINT);
        _;
    }

    function setUp() public {
        deployer = new DecentralizedStableCoinDeploy();
        (stableCoin, engine, helperConfig) = deployer.run();
    }

    /*//////////////////////////////////////////////////////////////
                               MINT TESTS
    //////////////////////////////////////////////////////////////*/
    function test_mintShouldRevertIfToIsAddressZero() public {
        vm.prank(address(engine));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NotZeroAddress.selector);
        stableCoin.mint(ZERO_ADDRESS, DSC_TO_MINT);
    }

    function test_mintShouldRevertIfAmountIsZero() public {
        vm.prank(address(engine));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        stableCoin.mint(USER, ZERO);
    }

    function test_mintShouldReturnTrue() public {
        vm.prank(address(engine));

        bool success = stableCoin.mint(USER, DSC_TO_MINT);
        assertTrue(success);
    }

    /*//////////////////////////////////////////////////////////////
                               BURN TESTS
    //////////////////////////////////////////////////////////////*/
    function test_burnShouldRevertIfAmountIsZero() public {
        vm.prank(address(engine));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        stableCoin.burn(ZERO);
    }

    function test_burnShouldRevertIfNotEnoughBalance() public {
        vm.prank(address(engine));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        stableCoin.burn(DSC_TO_BURN);
    }

    //    function test_burnShouldReturnTrue() public {
    //        vm.prank(address(engine));
    //
    //        bool success = stableCoin.mint(USER, DSC_TO_MINT);
    //        assertTrue(success);
    //    }
}
