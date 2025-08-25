// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DecentralizedStableCoinDeploy} from "../../script/DecentralizedStableCoinDeploy.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    DecentralizedStableCoinDeploy private deployer;
    DecentralizedStableCoin private stableCoin;
    DSCEngine private engine;
    HelperConfig private helperConfig;
    address private eth_usd_PriceFeed;
    address private btc_usd_PriceFeed;
    address private weth;
    address private wbtc;
    uint256 private collateralToCover = 20 ether;

    address public USER = makeAddr("USER");
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant COLLATERAL_TO_REDEEM = 2 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DSC_TO_MINT = 100 ether;
    uint256 public constant DSC_TO_BURN = 5 ether;
    uint256 public constant DEBT_TO_COVER = 2 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier mintedDSC() {
        vm.startPrank(USER);
        stableCoin.approve(address(engine), STARTING_ERC20_BALANCE);
        engine.mintDSC(STARTING_ERC20_BALANCE);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDSC() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        stableCoin.approve(address(engine), STARTING_ERC20_BALANCE);
        engine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, STARTING_ERC20_BALANCE);
        vm.stopPrank();
        _;
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, DSC_TO_MINT);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(eth_usd_PriceFeed).updateAnswer(ethUsdUpdatedPrice);
        //        uint256 userHealthFactor = engine.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDSC(weth, collateralToCover, DSC_TO_MINT);
        stableCoin.approve(address(engine), DSC_TO_MINT);
        engine.liquidate(weth, USER, DSC_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DecentralizedStableCoinDeploy();
        (stableCoin, engine, helperConfig) = deployer.run();

        (eth_usd_PriceFeed, btc_usd_PriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    /*//////////////////////////////////////////////////////////////
                       CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    function test_revertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(eth_usd_PriceFeed);
        priceFeedAddresses.push(btc_usd_PriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(stableCoin));
    }

    /*//////////////////////////////////////////////////////////////
                           PRICE FEEDS TESTS
    //////////////////////////////////////////////////////////////*/
    function test_getAccountCollateralValue() public depositedCollateral {
        uint256 actualCollateralValueInUSD = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = engine.getUSDValue(weth, COLLATERAL_AMOUNT);
        assertEq(expectedCollateralValue, actualCollateralValueInUSD);
    }

    function test_getUSDValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000$ for each ETH = 30.000e18
        uint256 expectedUSD = 30000e18;
        uint256 actualUSD = engine.getUSDValue(weth, ethAmount);
        assertEq(expectedUSD, actualUSD);
    }

    function test_getTokenAmountFromUSD() public view {
        uint256 usdAmount = 100 ether;
        // 100$ (usdAmountInWei) / 2000$ ETH (token's price) = 0.05
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUSD(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/
    function test_depositCollateral_revertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDSC = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDSC)];
        priceFeedAddresses = [eth_usd_PriceFeed];
        vm.prank(owner);
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.mint(USER, COLLATERAL_AMOUNT);

        vm.prank(owner);
        mockDSC.transferOwnership(address(mockEngine));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDSC)).approve(address(mockEngine), COLLATERAL_AMOUNT);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.depositCollateral(address(mockDSC), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_depositCollateral_revertIfAmountIsZero() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_depositCollateral_revertWithUnapprovedCollateral() public {
        ERC20Mock unapprovedToken = new ERC20Mock();

        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(unapprovedToken), COLLATERAL_AMOUNT);

        vm.stopPrank();
    }

    function test_depositCollateral_canDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = stableCoin.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function test_depositCollateral_canDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedCollateralValue = engine.getTokenAmountFromUSD(weth, collateralValueInUSD);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(COLLATERAL_AMOUNT, expectedDepositedCollateralValue);
    }

    /*//////////////////////////////////////////////////////////////
                MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/
    function test_mintDSC_revertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDSC(0);
        vm.stopPrank();
    }

    function test_mintDSC_mintRevertIfHealthFactorIsBroken() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(eth_usd_PriceFeed).latestRoundData();
        uint256 amountToMint =
            (COLLATERAL_AMOUNT * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUSDValue(weth, COLLATERAL_AMOUNT));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDSC(amountToMint);
        vm.stopPrank();
    }

    function test_mintDSC_canMintDSC() public depositedCollateralAndMintedDSC {
        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        uint256 userDSC = stableCoin.balanceOf(USER);

        assertEq(totalDscMinted, STARTING_ERC20_BALANCE);
        assertEq(userDSC, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                DEPOSIT COLLATERAL AND MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/
    function test_depositCollateralAndMintDSC_revertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDSC = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [eth_usd_PriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.transferOwnership(address(mockEngine));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockEngine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockEngine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, DSC_TO_MINT);
        vm.stopPrank();
    }

    function test_depositCollateralAndMintDSC_revertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(eth_usd_PriceFeed).latestRoundData();
        uint256 amountToMint =
            (COLLATERAL_AMOUNT * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);

        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUSDValue(weth, COLLATERAL_AMOUNT));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();
    }

    function test_depositCollateralAndMintDSC_canDepositCollateralAndMintDSC() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);

        engine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, DSC_TO_MINT);

        (uint256 totalDscMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);

        uint256 expectedDepositedCollateralValue = engine.getTokenAmountFromUSD(weth, collateralValueInUSD);

        assertEq(totalDscMinted, DSC_TO_MINT);
        assertEq(COLLATERAL_AMOUNT, expectedDepositedCollateralValue);
    }

    /*//////////////////////////////////////////////////////////////
            BURN DSC TESTS
    //////////////////////////////////////////////////////////////*/
    function test_burnDSC_revertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDSC(0);
        vm.stopPrank();
    }

    function test_burnDSC_cantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDSC(1);
    }

    function test_burnDSC_burnRevertIfExceedsBalance() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);

        uint256 excessiveBurnAmount = STARTING_ERC20_BALANCE + 1 ether;
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreTokens.selector);
        engine.burnDSC(excessiveBurnAmount);

        vm.stopPrank();
    }

    function test_burnDSC_canBurnDSC() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);
        engine.burnDSC(DSC_TO_BURN);
    }

    /*//////////////////////////////////////////////////////////////
        REDEEM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/
    function test_redeemCollateral_revertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDSC = new MockFailedTransfer();
        tokenAddresses = [address(mockDSC)];
        priceFeedAddresses = [eth_usd_PriceFeed];
        vm.prank(owner);
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.mint(USER, COLLATERAL_AMOUNT);

        vm.prank(owner);
        mockDSC.transferOwnership(address(mockEngine));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDSC)).approve(address(mockEngine), COLLATERAL_AMOUNT);
        // Act / Assert
        mockEngine.depositCollateral(address(mockDSC), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.redeemCollateral(address(mockDSC), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_redeemCollateral_redeemRevertIfAmountIsZero() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
    }

    function test_redeemCollateral_redeemRevertIfBreaksHealthFactor() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);

        bytes memory expectedRevert = abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0);
        vm.expectRevert(expectedRevert);
        engine.redeemCollateral(weth, COLLATERAL_AMOUNT);
    }

    function test_redeemCollateral_canRedeemCollateral() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(USER, USER, weth, COLLATERAL_AMOUNT);

        vm.startPrank(USER);
        engine.redeemCollateral(weth, COLLATERAL_AMOUNT);

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, COLLATERAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
            REDEEM COLLATERAL AND BURN DSC TESTS
    //////////////////////////////////////////////////////////////*/
    function test_redeemCollateralForDSC_mustRedeemMoreThanZero() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);
        stableCoin.approve(address(engine), DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreTokens.selector);
        engine.redeemCollateralForDSC(weth, 0, DSC_TO_MINT);
        vm.stopPrank();
    }

    function test_redeemCollateralForDSC_canRedeemCollateralAndBurnDSC() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        stableCoin.approve(address(engine), DSC_TO_BURN);

        engine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, DSC_TO_MINT);

        engine.redeemCollateralForDSC(weth, COLLATERAL_TO_REDEEM, DSC_TO_BURN);

        (uint256 totalDscMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);

        uint256 expectedDepositedCollateralValue = engine.getTokenAmountFromUSD(weth, collateralValueInUSD);

        assertEq(totalDscMinted, DSC_TO_MINT - DSC_TO_BURN);
        assertEq(COLLATERAL_AMOUNT - COLLATERAL_TO_REDEEM, expectedDepositedCollateralValue);
    }

    /*//////////////////////////////////////////////////////////////
            HEALTH FACTOR TESTS
    //////////////////////////////////////////////////////////////*/
    // TODO: Fix it
    //    function test_getHealthFactor_properlyReportsHealthFactor() public depositedCollateralAndMintedDSC {
    //        uint256 expectedHealthFactor = 100 ether;
    //        uint256 healthFactor = engine.getHealthFactor(USER);
    //        // $100 minted with $20,000 collateral at 50% liquidation threshold
    //        // means that we must have $200 collatareral at all times.
    //        // 20,000 * 0.5 = 10,000
    //        // 10,000 / 100 = 100 health factor
    //        assertEq(healthFactor, expectedHealthFactor);
    //    }

    // TODO: Fix it
    //    function test_getHealthFactor_healthFactorCanGoBelowOne() public depositedCollateralAndMintedDSC {
    //        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    //        // Remember, we need $200 at all times if we have $100 of debt
    //
    //        MockV3Aggregator(eth_usd_PriceFeed).updateAnswer(ethUsdUpdatedPrice);
    //
    //        uint256 userHealthFactor = engine.getHealthFactor(USER);
    //        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
    //        // 0.9
    //        assert(userHealthFactor == 0.9 ether);
    //    }

    /*//////////////////////////////////////////////////////////////
            LIQUIDATE TESTS
    //////////////////////////////////////////////////////////////*/
    function test_liquidate_mustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDSC = new MockMoreDebtDSC(eth_usd_PriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [eth_usd_PriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.transferOwnership(address(mockEngine));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockEngine), COLLATERAL_AMOUNT);
        mockEngine.depositCollateralAndMintDSC(weth, COLLATERAL_AMOUNT, DSC_TO_MINT);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(mockEngine), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockEngine.depositCollateralAndMintDSC(weth, collateralToCover, DSC_TO_MINT);
        mockDSC.approve(address(mockEngine), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(eth_usd_PriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function test_liquidate_cantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDSC {
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDSC(weth, collateralToCover, DSC_TO_MINT);
        stableCoin.approve(address(engine), DSC_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        engine.liquidate(weth, USER, DSC_TO_MINT);
        vm.stopPrank();
    }

    function test_liquidate_liquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = engine.getTokenAmountFromUSD(weth, DSC_TO_MINT)
            + (
                engine.getTokenAmountFromUSD(weth, DSC_TO_MINT) * engine.getLiquidationBonus()
                    / engine.getLiquidationPrecision()
            );
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function test_liquidate_userStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUSD(weth, DSC_TO_MINT)
            + (
                engine.getTokenAmountFromUSD(weth, DSC_TO_MINT) * engine.getLiquidationBonus()
                    / engine.getLiquidationPrecision()
            );

        uint256 usdAmountLiquidated = engine.getUSDValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = engine.getUSDValue(weth, COLLATERAL_AMOUNT) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function test_liquidate_liquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, DSC_TO_MINT);
    }

    function test_liquidate_userHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }
}
