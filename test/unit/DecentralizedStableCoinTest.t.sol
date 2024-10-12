// SPDX-License-Identifier: MIT


pragma solidity ^0.8.18;

import { Test, console } from "forge-std/Test.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
import { DeployDSC } from "../../script/DeployDSC.s.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DecentralizedStableCoinTest is Test {
    HelperConfig config;
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;

    address weth;
    address wbtc;
    address ethPriceFeed;
    address btcPriceFeed;

    address public user = makeAddr("user");
    uint256 public constant MINT_AMOUNT = 1e18;
    uint256 public constant MORE_THAN_MINT_AMOUNT = 1e20;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
      
    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethPriceFeed, btcPriceFeed, weth, wbtc,) = config.activeNetWorkConfig();

        ERC20Mock(weth).mint(user, STARTING_ERC20_BALANCE);
    }

    modifier depositedCollateralAndMinted() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), STARTING_ERC20_BALANCE);
        dsce.depositCollateralAndMintDsc(address(weth), STARTING_ERC20_BALANCE, MINT_AMOUNT);
        vm.stopPrank();
        _;
    }
    modifier mintedAfterRealization() {
        vm.startPrank(address(dsce));
        dsc.mint(address(dsce), MINT_AMOUNT);
        vm.stopPrank();
        _;
    }

    ////////////////////
    //// burn //////////
    ////////////////////
    function testBurnRevertsIfAmountIsZero() public mintedAfterRealization{
        vm.startPrank(address(dsce));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
        vm.stopPrank();
    }

    function testBurnRevertsIfAmountExceedsBalance() public mintedAfterRealization{
        vm.startPrank(address(dsce));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(MORE_THAN_MINT_AMOUNT);
        console.log("DSCEngine balance: ", dsc.balanceOf(address(dsce)));
        console.log("User balance: ", dsc.balanceOf(user));
        console.log("Total DSC supply: ", dsc.totalSupply());
        vm.stopPrank();
    }

    function testBurnIsSuccessful() public mintedAfterRealization{
        // Arrange
        vm.startPrank(address(dsce));
        
        // Act
        dsc.burn(MINT_AMOUNT);

        // Assert
        uint256 expectedAmount = 0;
        uint256 actualAmount = dsc.totalSupply(); // 0
        assertEq(expectedAmount, actualAmount);
    }

    //////////////////
    ///// mint////////
    //////////////////
    function testMintRevertsIfToZeroAddress() public {
        vm.startPrank(address(dsce));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NotZeroAddress.selector);
        dsc.mint(address(0), MINT_AMOUNT);
        vm.stopPrank();
    }

    function testMintRevertsIfAmountIsZero() public {
        vm.startPrank(address(dsce));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.mint(user, 0);
        vm.stopPrank();
    }

    function testMintIsSuccessful() public mintedAfterRealization{
        uint256 expectedAmount = MINT_AMOUNT;
        uint256 actualAmount = dsc.balanceOf(address(dsce));

        assertEq(expectedAmount, actualAmount);
    }

    function testMintReturnsTrue() public {
        vm.prank(address(dsce));
        bool minted = dsc.mint(user, MINT_AMOUNT);

        assert(minted = true);
    }
}