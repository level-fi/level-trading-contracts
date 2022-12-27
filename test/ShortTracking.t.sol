// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {Pool, TokenWeight, Side} from "../src/pool/Pool.sol";
import {PoolAsset, PositionView, PoolLens} from "./PoolLens.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ILPToken} from "../src/interfaces/ILPToken.sol";
import {PoolErrors} from "../src/pool/PoolErrors.sol";
import {LPToken} from "../src/tokens/LPToken.sol";
import {PositionUtils} from "../src/lib/PositionUtils.sol";
import {PoolTestFixture} from "./Fixture.sol";
import {SignedInt, SignedIntOps} from "../src/lib/SignedInt.sol";

contract ShortTrackingTest is PoolTestFixture {
    using SignedIntOps for SignedInt;
    address tranche;

    function setUp() external {
        build();
        vm.startPrank(owner);
        tranche = address(new LPToken("LLP", "LLP", address(pool)));
        pool.addTranche(tranche);
        Pool.RiskConfig[] memory config = new Pool.RiskConfig[](1);
        config[0] = Pool.RiskConfig(tranche, 1000);
        pool.setRiskFactor(address(btc), config);
        pool.setRiskFactor(address(weth), config);
        vm.stopPrank();
    }

    function _beforeTestPosition() internal {
        vm.prank(owner);
        pool.setOrderManager(orderManager);
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(btc), 20000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.startPrank(alice);
        btc.mint(2e8);
        usdc.mint(1000000e6);
        vm.deal(alice, 1e18);
        vm.stopPrank();
    }

    function testShortPosition() external {
        vm.startPrank(owner);
        pool.setPositionFee(0, 0);
        pool.setInterestRate(0, 1);
        vm.stopPrank();
        _beforeTestPosition();

        // add liquidity
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(usdc), 1000000e6, 0, alice);
        vm.stopPrank();

        vm.startPrank(orderManager);
        // OPEN SHORT position with 5x leverage
        vm.warp(1000);
        oracle.setPrice(address(btc), 20000e22);
        usdc.mint(2000e6);
        usdc.transfer(address(pool), 2000e6); // 0.1BTC = 2_000$
        pool.increasePosition(alice, address(btc), address(usdc), 10_000e30, Side.SHORT);
        vm.warp(1100);
        oracle.setPrice(address(btc), 20050e22);
        usdc.mint(2000e6);
        usdc.transfer(address(pool), 2000e6); // 0.1BTC = 2_000$
        pool.increasePosition(bob, address(btc), address(usdc), 10_000e30, Side.SHORT);

        {
            PositionView memory alicePosition =
                lens.getPosition(address(pool), alice, address(btc), address(usdc), Side.SHORT);
            PositionView memory bobPosition =
                lens.getPosition(address(pool), bob, address(btc), address(usdc), Side.SHORT);

            uint256 indexPrice = 19000e22;
            SignedInt memory totalPnL = PositionUtils.calcPnl(
                Side.SHORT, alicePosition.size, alicePosition.entryPrice, indexPrice
            ).add(PositionUtils.calcPnl(Side.SHORT, bobPosition.size, bobPosition.entryPrice, indexPrice));
            console.log("total PnL", totalPnL.sig, totalPnL.abs);

            PoolAsset memory poolAsset = lens.poolAssets(address(pool), address(btc));
            console.log("global short position", poolAsset.totalShortSize, poolAsset.averageShortPrice);
            SignedInt memory globalPnL =
                PositionUtils.calcPnl(Side.SHORT, poolAsset.totalShortSize, poolAsset.averageShortPrice, indexPrice);
            console.log("global PnL", globalPnL.sig, globalPnL.abs);
            // allow some small rouding error
            assertTrue(diff(globalPnL.abs, totalPnL.abs, 1e18) <= 1);
        }

        // CLOSE partial short
        pool.decreasePosition(alice, address(btc), address(usdc), 1_000e30, 5_000e30, Side.SHORT, alice);

        {
            PositionView memory alicePosition =
                lens.getPosition(address(pool), alice, address(btc), address(usdc), Side.SHORT);
            PositionView memory bobPosition =
                lens.getPosition(address(pool), bob, address(btc), address(usdc), Side.SHORT);

            uint256 indexPrice = 19000e22;
            SignedInt memory totalPnL = PositionUtils.calcPnl(
                Side.SHORT, alicePosition.size, alicePosition.entryPrice, indexPrice
            ).add(PositionUtils.calcPnl(Side.SHORT, bobPosition.size, bobPosition.entryPrice, indexPrice));
            console.log("total PnL", totalPnL.sig, totalPnL.abs);

            PoolAsset memory poolAsset = lens.poolAssets(address(pool), address(btc));
            console.log("global short position", poolAsset.totalShortSize, poolAsset.averageShortPrice);
            SignedInt memory globalPnL =
                PositionUtils.calcPnl(Side.SHORT, poolAsset.totalShortSize, poolAsset.averageShortPrice, indexPrice);
            console.log("global PnL", globalPnL.sig, globalPnL.abs);
            assertTrue(diff(globalPnL.abs, totalPnL.abs, 1e18) <= 1);
        }
    }

    function diff(uint256 a, uint256 b, uint256 precision) internal view returns (uint256) {
        uint256 sub = a > b ? a - b : b - a;
        console.log( sub * precision / b);
        return sub * precision / b;
    }
}
