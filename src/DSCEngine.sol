// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.22;

/*
 * @title DSCEngine
 * @author Allen George 
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * - It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 * 
 * - Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * - @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    //State variables
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // We need to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; //This means a 10% bonus 10/100
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    //200% overcollaterilzation <-> 110% , Safe Zone
    //50% collateralization

    mapping(address token => address priceFeeds) private s_priceFeeds; //tokentoPriceFeed
    mapping(address user => mapping(address => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) s_DSCMinted;

    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    //Events
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    //Modifiers
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
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

    //Constructors
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        //For example ETH/USD , BTC/USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; //token of i = pricefeed of i
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @notice this function will deposit your collateral and mint DSC in one transaction
    */

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /* Notice follows CEI
    * The description of the functions
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant //Imp attack in Web3, most functions must be nonRentrant , but it's a bit more gas intensive...
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of Dsc to burn
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
    }

    //Threshold to let's say 150%
    //$100ETH -> $60 ETH
    //$50 DSC ->
    //Do we need to check if this breaks health factor?

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit.....
    }

    /**
     * In order to redeem collateral:
     * 1. Health factor must be 1 After collateral is pulled
     * 2. DRY: Don't repeat yourself
     * CEI: Check, Effects, Interactions
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // $100  -> $20 DSC
    //100(break) If redeem all your eth , it will break your health factor
    // 1. burn DSC
    // 2. Redeem Eth

    /*
     * 
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshol
     */

    //1. Check if the collateral value is greater than DSC amount. Price feeds
    //People deposits $20ETH --> and want to mint only $20 DSC

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    //If we start nearing undercolateralization, we need someone to liquidate positions
    // $100 ETH backing $50 DSC
    // $20 ETH back $50 <- DSC isn't worth $1 !!
    //$75 backing $50 DSC
    //liquidator take $75 backing and burns off the $50 DSC
    //If someone is almost undercollateralized, we will pay you to liquidate them!

    /**
     *
     * @param collateral The ERC20 collateral address to liquidate
     * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR ..Value Of Collaterals/Value Of borrowed assets
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcolletralized
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // If health factor is perfect
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        //We want to burn their DSC "debt" and take their collateral
        //Bad user: $140 ETH, $100 DSC
        // $100 of DSC = ??ETH
        // 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        //We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

        //0.05 ETH * .1 = 0.005 ETH. Get 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // We need to burn the dsc
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                     PRIVATE AND INTERNAL  VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *
     * @param amountDscToBurn Amount of dsc to burn
     * @param onBehalfOf Who gets it
     * @param dscFrom Wh
     * @dev Low level internal function , do not call unless the function calling it is checking for health factors for being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        //Hypothetically unreachable as
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _healthFactor(address user) private view returns (uint256) {
        //Get total DSC minted , get total collateral value
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDSCMinted == 0) revert DSCEngine__HealthFactorOk(); //This means no debt
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted; //If this is <1 you will get liquidated
            //1000 ETH*50 = 50000/100 = 500
            // $150 ETH / 100 DSC = 1.5
            // 150*50 = 7500/100 = (75/100) = 0.75
            // return (collateralValueInUsd / totalDSCMinted); //(150/100) , if we go down a penny we'll be under collateralized..Thus set the threshold higher, like 150 so that under 150 you'' get liquidated
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. Check health factor , check aave documentation..Revert if the don't
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = _getAccountCollateralValueInUsd(user);
    }

    /*//////////////////////////////////////////////////////////////
                     PUBLIC AND EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of ETH(token)
        // $/ETH ETH??
        // $2000 / ETH ,We have $1000... = 0.5 ETH i.e usdAmountInWei/Price
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18*1e18)/ ($2000e18*1e10)

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function _getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount they deposited and map it to the price, to get the USD

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdInValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdInValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLastestRoundData();

        //1 ETH = $1000
        // The returned value from CL will be 1000*1e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //(1000*1e8)*(1e10)*1000*1e18;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokensPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256 balance) {
        return s_collateralDeposited[user][token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getTokenAddress(address tokenId) external view returns (address) {
        return s_priceFeeds[tokenId];
    }
}
