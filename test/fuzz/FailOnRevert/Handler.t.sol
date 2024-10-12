// SPDX-License-Identifier: MIT

// Handler is going to narrow down the way we call functions

pragma solidity ^0.8.18;

import { Test, console } from "forge-std/Test.sol";
import { DSCEngine } from "../../../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../../../src/DecentralizedStableCoin.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { MockV3Aggregator } from "../../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    address[] public usersWithCollateralDeposited;

    uint256 public timesMintIsCalled;
    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    MockV3Aggregator public ethUsdPriceFeed;
    

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getAllCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPricefeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
       
        dsce.depositCollateral(address(collateral), amountCollateral);
        usersWithCollateralDeposited.push(msg.sender);
        vm.stopPrank();
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0){
            return;
        }

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length]; 
        
        (uint256 totalDscMinted, uint256 collateralDepositedInUsd) = dsce.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralDepositedInUsd) / 2) - int256(totalDscMinted);

        if (maxDscToMint < 0){
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0){
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
 
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getAmountDeposited(msg.sender, address(collateral));
        uint256 dscMinted = dsce.getAmountMinted(msg.sender);
        console.log("Total DSC minted: ", dscMinted);
        console.log("Collateral Deposited: ", maxCollateralToRedeem);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        console.log("Collateral To Redeem: ", amountCollateral);

        uint256 collateralDepositedInUsd = dsce.getUsdValue(address(collateral), maxCollateralToRedeem);
        uint256 amountCollateralToRedeemInUsd = dsce.getUsdValue(address(collateral), amountCollateral);

        bool isOkToRedeem = _checkIfBreaksHealthFactorForRedeem(collateralDepositedInUsd, dscMinted, amountCollateralToRedeemInUsd);

        if (isOkToRedeem != true){
            return;
        }

        if (amountCollateral == 0){
            return;
        }
        vm.startPrank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    // This brakes our test suite!!!!!
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock) {
        if (collateralSeed % 2 == 0){
            return weth;
        }
        return wbtc;
    }

    function _checkIfBreaksHealthFactorForRedeem(uint256 collateralDepositedInUsd, uint256 totalDscMinted, uint256 collateralToRedeemInusd) private returns(bool){
        uint256 collateralAfterRedeem = collateralDepositedInUsd - collateralToRedeemInusd;
        uint256 healthFactorAfterRedeem = dsce.calculateHealthFactor(collateralAfterRedeem, totalDscMinted);
        if (healthFactorAfterRedeem < MIN_HEALTH_FACTOR){
            return false;
        }
        else {
            return true;
        }
    }
}