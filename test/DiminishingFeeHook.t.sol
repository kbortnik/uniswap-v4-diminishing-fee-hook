// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { Pool } from "v4-core/src/libraries/Pool.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { CurrencyLibrary, Currency } from "v4-core/src/types/Currency.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";
import { DiminishingFeeHook } from "../src/DiminishingFeeHook.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";

import { LiquidityAmounts } from "v4-core/test/utils/LiquidityAmounts.sol";
import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { EasyPosm } from "./utils/EasyPosm.sol";
import { Fixtures } from "./utils/Fixtures.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Constants } from "v4-core/test/utils/Constants.sol";

import "forge-std/console2.sol";

contract DiminishingFeeHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using Pool for Pool.State;

    address user = address(0xBEEF);

    DiminishingFeeHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));

        uint24[] memory feeTiers = new uint24[](7);
        feeTiers[0] = 150_000; // 15%
        feeTiers[1] = 70_000; // 7%
        feeTiers[2] = 50_000; // 5%
        feeTiers[3] = 20_000; // 2%
        feeTiers[4] = 10_000; // 1%
        feeTiers[5] = 5_000; // 0.5%
        feeTiers[6] = 2_500; // 0.25%

        uint256[] memory timeThresholds = new uint256[](6);
        // First fee tier starts immediately!
        timeThresholds[0] = 10; // 10 mins after pool init
        timeThresholds[1] = 130; // 120 min after tier 1
        timeThresholds[2] = 250; // 120 min after tier 2
        timeThresholds[3] = 370; // 120 min after tier 3
        timeThresholds[4] = 490; // 120 min after tier 4
        timeThresholds[5] = 1440; // 950 min after tier 5

        bytes memory constructorArgs = abi.encode(manager, feeTiers, timeThresholds, user);
        deployCodeTo("DiminishingFeeHook.sol:DiminishingFeeHook", constructorArgs, flags);
        hook = DiminishingFeeHook(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 0x800000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 1000_000e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId, ) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function _defaultTestSettings() internal returns (PoolSwapTest.TestSettings memory testSetting) {
        return PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });
    }

    function _warpAndSwap(uint256 durationMinutes, uint256 expectedReceivedAmount) internal {
        vm.warp(block.timestamp + durationMinutes * 60);

        int256 amountSpecified = -1e18; // Negative number indicates exact input swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amountSpecified),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        uint256 currency1Before = currency1.balanceOfSelf();

        swapRouter.swap(key, params, settings, ZERO_BYTES);

        uint256 currency1After = currency1.balanceOfSelf();

        assertApproxEqAbs(currency1After - currency1Before, expectedReceivedAmount, 0.0001 ether);

        if (durationMinutes > 0) {
            console2.log("%d minutes later...", durationMinutes);
        }
        console2.log("Expected received amount: %e", expectedReceivedAmount);
        console2.log("Actual received amount: %e", currency1After - currency1Before);
        console2.log("Fee: %e\n", 1e18 - expectedReceivedAmount);
    }

    function testDiminishingFeeHooks() public {
        _warpAndSwap(0, 0.850e18);
        _warpAndSwap(5, 0.850e18);
        _warpAndSwap(10, 0.930e18);
        _warpAndSwap(120, 0.950e18);
        _warpAndSwap(120, 0.980e18);
        _warpAndSwap(120, 0.990e18);
        _warpAndSwap(120, 0.995e18);
        _warpAndSwap(950, 0.9975e18);
    }

    function _setApprovalsFor(address _user, address token) internal {
        address[8] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor())
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            vm.prank(_user);
            MockERC20(token).approve(toApprove[i], Constants.MAX_UINT256);
        }
    }
}
