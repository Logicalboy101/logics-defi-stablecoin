// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethPriceFeed;
        address wbtcPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetWorkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetWorkConfig = getSepoliaEthConfig();
        }
        if (block.chainid == 31337) {
            activeNetWorkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        NetworkConfig({
            wethPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcPriceFeed: 0x5fb1616F78dA7aFC9FF79e0371741a747D2a7F22,
            weth: 0x5fb1616F78dA7aFC9FF79e0371741a747D2a7F22,
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetWorkConfig.wethPriceFeed != address(0)) {
            return activeNetWorkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        ERC20Mock wethMock = new ERC20Mock();
        vm.stopBroadcast();

        vm.startBroadcast();
        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        ERC20Mock wbtcMock = new ERC20Mock();
        vm.stopBroadcast();

        return NetworkConfig({
            wethPriceFeed: address(ethUsdPriceFeed),
            wbtcPriceFeed: address(btcUsdPriceFeed),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}
