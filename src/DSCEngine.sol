// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import { console } from "forge-std/Test.sol";

/**
 * @title DSCEngine.
 * @author Logic.
 *
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * -> Exogenous Collateral.
 * -> Dollar Pegged.
 * -> Algorithimically stable.
 *
 * It is similar to DAI if DAI has no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC should always be "overcollateralized". At no point should the total value of collateral
 *  be <= the total $ backed value of the DSC
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC,
 *  as well as depositing and withdrawing collateral.
 * @notice This contract is loosely based on the MakerDAO DSS(DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////////////////
    /////// Errors   ////////////
    /////////////////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAdressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////////////
    /////// Types   /////////////
    /////////////////////////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////////////
    /////// State Variables   ///
    /////////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus

    /////////////////////////////
    /////// Events            ///
    /////////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /////////////////////////////
    /////// Modifiers   /////////
    /////////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier AllowedToken(address token) {
        if (token == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        if (token != s_collateralTokens[0] && token != s_collateralTokens[1]) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////////////////
    /////// Functions   /////////
    /////////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddresss) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAdressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddresss);
    }

    /////////////////////////////
    /////// External Functions //
    /////////////////////////////
    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress: The address of the token to deposit as collateral.
     * @param amountCollateral: The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        AllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToBurn: The amount of DSC you want to burn
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeeemCollateral already checks healthFactor
    }

    /*
    * Follows CEI
    * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
    * @param amountCollateral: The amount of collateral you're redeeming
    * @notice In order to redeem collateral:
    *   1. Health Factor must be OVER 1 after collateral is pulled
    * @notice This function will redeem your collateral.
    * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
    */
    // DRY: Don't repeat yourself(computer sctence concept)
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        AllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * Follows CEI
     * @param amountDscToMint: The amount of Decentralzed stablecoin to mint
     * @notice THey must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much ($150 DSC => $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this line will hit either...
    }

    // If someone is undercollatralized we will pay you to lo liquidate them!
    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * Follows CEI.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

 

    ////////////////////////////////////////////
    /////// Private & Internal view Functions //
    ////////////////////////////////////////////

    /**
     * @dev Low-Level Internal Function: Do not call unless the function calling is is checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
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
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        //uint256 amountRemaining = s_collateralDeposited[from][tokenCollateralAddress];
        // console.log("Collateral Remaining: ", amountRemaining);
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _calculateHealthFactor(uint256 amountCollateralInUsd, uint256 amountDsc) internal returns(uint256 healthFactor) {
        if (amountDsc == 0) {
            return type(uint96).max;
        }
        
        uint256 amountCollateralAdjusted = (amountCollateralInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (amountCollateralAdjusted * 1e18) / amountDsc;
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralDepositedInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralDepositedInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close a user is to liquidation.
     * if a user goes below 1, they can be liquidated
     */
    function _healthFactor(address user) internal returns (uint256) {
        // get the amount of DSC minted
        // get the total value of collateral
        (uint256 totalDscMinted, uint256 collateralValue) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return type(uint96).max;
        }
        uint256 collateralValueAdjusted = (collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralValueAdjusted * PRECISION) / totalDscMinted;
        //return(collateralValue / totalDscMinted);
    }

    // Check Health Factor (Do they Have Enough Collateral?)
    // revert If they don't
    function _revertIfHealthFactorIsBroken(address user) internal {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////////
    /////// Public & External view Functions ///
    ////////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralDepositedInUsd)
    {
        (totalDscMinted, collateralDepositedInUsd) = _getAccountInformation(user);
    }

    function getAmountDeposited(address user, address token) public view returns (uint256 amountDeposited) {
        amountDeposited = s_collateralDeposited[user][token];
    }

    function getAmountMinted(address user) public view returns (uint256 amountMinted) {
        amountMinted = s_DSCMinted[user];
    }

    function getHealthFactor(address user) external returns(uint256 healthFactor) {
        healthFactor = _healthFactor(user);
    }

    function getCollateralTokens() public view returns (address wantedToken) {
        wantedToken = s_collateralTokens[1];
    }

    function calculateHealthFactor(uint256 collateralAmountInUsd, uint256 amountDscMinted) public returns(uint256) {
        return _calculateHealthFactor(collateralAmountInUsd, amountDscMinted);
    }

    function getAllCollateralTokens() public view returns(address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPricefeed(address token) public view returns(address){
        token = s_priceFeeds[token];
    }

    // function setAmount(address token, address user, uint256 newAmount) public{
    //     s_collateralDeposited[user][token] = newAmount;
    // }

}
