// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    HelperConfig config;
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    address weth;
    address wbtc;
    address ethPriceFeed;
    address btcPriceFeed;

    address public USER = makeAddr("user");
    address public YOURBOI = makeAddr("yourboi");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 1000 ether;
    uint256 public constant AMOUNT_MINT = 2 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethPriceFeed, btcPriceFeed, weth, wbtc,) = config.activeNetWorkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(YOURBOI, STARTING_ERC20_BALANCE);
    }

    ////////////////////////////////
    ///// Constructor Tests ////////
    ////////////////////////////////
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function testIfTokenLengthDoesntMatchWithPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethPriceFeed);
        priceFeedAddresses.push(btcPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAdressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////////
    ///// Price Tests ////////
    //////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;

        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    //////////////////////////////////////
    ///// depositCollateral Tests ////////
    //////////////////////////////////////

    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = AMOUNT_COLLATERAL;

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);

        uint256 actualDepositAmount = dsce.getAmountDeposited(USER, address(weth));

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(actualDepositAmount, expectedDepositAmount);
    }

    function testRevertsWithUnwantedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);
        ERC20Mock(ranToken).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositCollateralEmits() public {
        vm.recordLogs();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 collateralDeposited = entries[0].topics[1];

        assert(collateralDeposited > 0);
    }

    //////////////////////////////////////
    ///// redeemCollateral Tests /////////
    //////////////////////////////////////
    modifier depositedAndRedeemedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testRedeemCollateralAndGetAccountInfoWithNoMint() public depositedAndRedeemedCollateral {
        uint256 expectedAmount = 0;
        uint256 actualAmount = dsce.getAmountDeposited(USER, weth);

        console.log(actualAmount);

        assertEq(expectedAmount, actualAmount);
    }

    function testRedeemCollateralAndGetAccountInfo() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(1000);
        dsce.redeemCollateral(weth, 1000);
        vm.stopPrank();

        uint256 expectedAmount = 9999999999999999000;
        uint256 actualAmount = dsce.getAmountDeposited(USER, weth);

        console.log(actualAmount);

        assertEq(expectedAmount, actualAmount);
    }

    function testRevertsIfHealthFactorIsBroken() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(5000);
        vm.expectRevert();
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralEmits() public {
        vm.recordLogs();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, 1000);
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 collateralRedeemed = entries[1].topics[1];

        assert(collateralRedeemed > 0);
    }

    //////////////////////////////////////
    ///// mintDsc Tests //////////////////
    //////////////////////////////////////
    modifier depositedCollateralAndMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        vm.stopPrank();
        _;
    }

    function testRecordsMint() public depositedCollateralAndMinted {
        uint256 expectedDscAmount = AMOUNT_MINT;
        uint256 actualDscAmount = dsce.getAmountMinted(USER);

        assertEq(expectedDscAmount, actualDscAmount);
    }

    function testRevertIfHealthFactorIsBroken() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert();
        dsce.depositCollateralAndMintDsc(weth, 1e15, AMOUNT_COLLATERAL); // Breaks HealthFactor
        vm.stopPrank();
    }

    //////////////////////////////////////
    ///// burnDsc Tests //////////////////
    //////////////////////////////////////

    modifier depositMintAndBurnDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), STARTING_ERC20_BALANCE);
        DecentralizedStableCoin(dsc).approve(address(dsce), AMOUNT_MINT);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        dsce.burnDsc(AMOUNT_MINT);
        _;
    }

    modifier breakHealthFactor() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), STARTING_ERC20_BALANCE);
        DecentralizedStableCoin(dsc).approve(address(dsce), AMOUNT_MINT);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 50 ether); // Breaks HealthFactor
        _;
    }

    function testBurnDscAndGetAccountInfo() public depositMintAndBurnDsc{
        vm.stopPrank();
        uint256 actualAmount = dsce.getAmountMinted(USER);
        uint256 expectedAmount = 0;

        assertEq(actualAmount, expectedAmount);
    }

    /////////////////////////////////////
    ////// liquidation Tests/////////////
    /////////////////////////////////////

    modifier liquidated() {
        int256 newAnswer = 190e6;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), STARTING_ERC20_BALANCE);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_COLLATERAL);
        DecentralizedStableCoin(dsc).approve(address(dsce), 20 ether);
        vm.stopPrank();
        vm.startPrank(YOURBOI);
        ERC20Mock(weth).approve(address(dsce), STARTING_ERC20_BALANCE);
        dsce.depositCollateralAndMintDsc(weth, 90 ether, AMOUNT_COLLATERAL);
        DecentralizedStableCoin(dsc).approve(address(dsce), STARTING_ERC20_BALANCE);
        MockV3Aggregator(ethPriceFeed).updateAnswer(newAnswer);
        dsce.liquidate(weth, USER, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated{
        uint256 actualCollateralAmount = dsce.getAmountDeposited(YOURBOI, weth);
        uint256 _actualCollateralAmount = dsce.getAmountDeposited(USER, weth);
        uint256 _actualDscAmount = dsce.getAmountMinted(USER);
        console.log(_actualDscAmount);

        console.log(_actualCollateralAmount);
        console.log(actualCollateralAmount);
        assert(actualCollateralAmount > 10e18);
        uint256 actualDscAmount = dsce.getAmountMinted(YOURBOI);
        console.log(actualDscAmount);
    }

    function testLiquidateRevertsWhenHealthFactorOk() public depositedCollateralAndMinted{
        vm.startPrank(YOURBOI);
        ERC20Mock(weth).approve(address(dsce), STARTING_ERC20_BALANCE);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 50 ether);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_MINT);
        vm.stopPrank();
    }


    /////////////////////////////////////
    ////// View & Pure Function Tests////
    /////////////////////////////////////

    function testGetAccountInfo() public depositedCollateralAndMinted{
        // Arrange
        vm.startPrank(USER);
        (uint256 totalDscMinted, uint256 collateralDepositedInUsd) = dsce.getAccountInformation(USER);
        vm.stopPrank();

        // Act / Assert
        uint256 expectedDscMinted = AMOUNT_MINT;
        uint256 expectedCollateralDepositedInUsd = AMOUNT_COLLATERAL * 2000;

        assertEq(expectedCollateralDepositedInUsd, collateralDepositedInUsd);
        assertEq(expectedDscMinted, totalDscMinted);
    }   

    function testGetsCollateralValue() public depositedCollateralAndMinted{
        // Act
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(wbtc, AMOUNT_COLLATERAL, AMOUNT_MINT);

        // Assert
        uint256 actualTotalCollateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedTotalCollateralValue = (AMOUNT_COLLATERAL * 2000) + (AMOUNT_COLLATERAL * 1000);

        assertEq(actualTotalCollateralValue, expectedTotalCollateralValue);
    }

    function testGetHealthFactor() public depositedCollateralAndMinted {
        // Act / Assert
        vm.startPrank(USER);
        uint256 actualHealthFactor = dsce.getHealthFactor(USER);
        uint256 expectedHealthFactor = 1e40;
    } 

    function testGetCollateralToken() public {
        address expectedTokenAddress = address(wbtc);
        address actualTokenAddress = dsce.getCollateralTokens();

        assert(expectedTokenAddress == actualTokenAddress);
    }

    function testCalculateHealthFactor() public {
        uint256 expectedAmount = 1e18;
        uint256 actualAmount = dsce.calculateHealthFactor(20e18, 10e18);

        assertEq(expectedAmount, actualAmount);
    }
}
 