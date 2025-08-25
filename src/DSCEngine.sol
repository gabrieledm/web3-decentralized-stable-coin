// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

/**
 * @title DecentralizedStableCoin
 * @author Gabriele Del Monte
 *
 * The system is designed to be as minimal as possible and have the tokens maintain a 1 token == 1$ peg.
 * The stablecoin has the properties:
 *   - Exogenous collateral
 *   - Dollar pegged
 *   - Algoritmically stable
 *
 * It is similar to DAI if DAI has no governance, no fees and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized".
 * At no point, should the value of all collateral (WETH and WBTC) <= the $ backed value of all DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                            TYPES
    //////////////////////////////////////////////////////////////*/
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__NeedMoreTokens();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor(address[] memory tokenAddresses, address[] memory priceFeedsAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedsAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedsAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @param tokenCollateralAddress - The address of the token to deposit as collateral
     * @param amountCollateral - The amount of collateral to deposit
     * @param amountDSCToMint - The amount of DecentralizedStableCoin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSCToMint);
    }

    /**
     * @notice Follows CEI pattern (Check, Effects, Interactions)
     * @param tokenCollateralAddress - The address of the token to deposit as collateral
     * @param amountCollateral - The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress - The address of the token from which  redeem the collateral
     * @param amountCollateral - The amount of collateral to redeem
     * @param amountDSCToBurn - The amount of decentralized stablecoin to burn
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn)
        external
    {
        // First burn DSC to not break the Health Factor when the collateral is redeemed
        burnDSC(amountDSCToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Follows CEI pattern (Check, Effects, Interactions)
     * @notice They must have more collateral value than the minimum threshold
     * @param amountDscToMint - The amount of decentralized stablecoin to mint
     */
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(msg.sender, msg.sender, amount);
        // Probably this is not necessary (the health factor will never be broken after DSC burn)
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice If someone is almost undercollateralized, we will pay you to liquidate them
     * @dev $20 ETH back by 50$ DSC <- DSC isn't worth 1$
     * @param tokenCollateralAddress - The ERC20 collateral address to liquidate from the user
     * @param user - The user who has broken the health factor. Their `_healthFactor` should be below `MIN_HEALTH_FACTOR`
     * @param debtToCover - The amount of DSC to be burned to increase the user's health factor
     * @notice Follows CEI pattern (Check, Effects, Interactions)
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the user's funds
     * @notice This function working assumes the protocol will re roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators.
     */
    function liquidate(address tokenCollateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Check Health Factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor > MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }

        // Bad User: 140$ ETH, 100$ DSC -> debtToCover = 100$
        // 100$ of DSC == ??? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(tokenCollateralAddress, debtToCover);
        // Give a 10% bonus
        // We are giving the liquidator $110 of ETH for 100 DSC
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // Take the user's collateral
        _redeemCollateral(user, msg.sender, tokenCollateralAddress, totalCollateralToRedeem);

        // burn the DSC debt
        _burnDSC(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // Revert also if the liquidate process ruins the health factor of the liquidator(=msg.sender)
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /*//////////////////////////////////////////////////////////////
                     PRIVATE AND INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Low-level internal function. Do not call unless the function calling it is checking for health factor being broken.
     */
    function _burnDSC(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        if (s_DSCMinted[onBehalfOf] < amountDscToBurn) {
            revert DSCEngine__NeedMoreTokens();
        }
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        // In order to redeem collateral
        // 1. Health Factor must be over 1 AFTER collateral is pulled
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    /**
     * @dev If a user goes below 1, then he can get liquidated
     * @notice Liquidated happens when the deposited collateral's value falls below a certain threshold of the debt value.
     * @notice When this happens, the borrower's position will be considered `undercollateralized` and the collateral will be liquidated.
     * @return How close to liquidation a user is
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
    }

    function _calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUSD)
        internal
        pure
        returns (uint256)
    {
        if (totalDSCMinted == 0) return type(uint256).max;

        // ($1000 ETH [collateralValueInUSD] * 50 [LIQUIDATION_THRESHOLD]) = 50.000 / 100 [LIQUIDATION_PRECISION] = 500 / 100 (totalDSCMinted) > 1
        // ($150 ETH [collateralValueInUSD] * 50 [LIQUIDATION_THRESHOLD]) = 7.500 / 100 [LIQUIDATION_PRECISION = 75 / 100 (totalDSCMinted) < 1
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _getUSDValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000$
        // The returned value from ChainLink PriceFeed will be 1000 * 1e8 (ETH/USD PriceFeed has 8 decimal places)
        // ((1000 * 1e8) * 1e10) * 1000 * 1e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice 1. Check health factor (does the user have enough collateral ?)
     * @notice 2. Revert if he doesn't have it
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. Check health factor (do they have enough collateral ?)
        //2. Revert if they don't
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
               PUBLIC AND EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getAccountCollateralValue(address user) public view returns (uint256 collateralValueInUSD) {
        // Loop through each collateral token
        // Get the amount they have deposited
        // Map it to the current price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            collateralValueInUSD += _getUSDValue(token, amount);
        }
        return collateralValueInUSD;
    }

    /**
     * @return The token amount based on USD amount expressed in Wei the user has and the token price
     * @param token - The address of the collateral token from which get the current price
     * @param usdAmountInWei - The USD value, expressed in Wei for precision, used as division nominator
     * @notice Example: 1000$ (usdAmountInWei) / 2000$ ETH (token's price) = 0.5 ETH
     */
    function getTokenAmountFromUSD(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Get the price of token
        // usdAmountInWei / token's price
        // 1000$ / 2000$ ETH = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        // (10000000000000000000 * 1000000000000000000) / (2000_00000000 * 10000000000) = 5_000_000_000_000_000 Wei (=0.005 ETH)
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUSD)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUSD);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        (totalDscMinted, collateralValueInUSD) = _getAccountInformation(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getUSDValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUSDValue(token, amount);
    }
}
