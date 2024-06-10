// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PointsHook} from "../src/PointsHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

import {LoyaltyCredentials} from "../src/Credentials.sol";

contract TestPointsHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 token;

    // credentials for using AMM
    LoyaltyCredentials loyaltyCredentials;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        loyaltyCredentials = new LoyaltyCredentials();


        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Deploy the PointsHook contract with additions 
        // Added Before Remove Liquidity (this is for lock-up period)
        // Added Before Add Liquidity (this is to verifiy liquidity license)
        // Added Before Swap (this is to verify trading credentials)
        address hookAddress = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG 
                    // | Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    // Hooks.BEFORE_SWAP_FLAG
            )
        );

        deployCodeTo(
            "PointsHook.sol",
            abi.encode(manager, "Points Token", "TEST_POINTS"),
            hookAddress
        );
        hook = PointsHook(hookAddress);

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // No additional `initData`
        );
    }

    function test_addLiquidityAndSwap() public {
        // Set no referrer in the hook data
        bytes memory hookData = hook.getHookData(address(0), address(this));

        uint256 pointsBalanceOriginal = hook.balanceOf(address(this));
        emit log_uint(pointsBalanceOriginal);

        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: 0
            }),
            hookData
        );
        uint256 pointsBalanceAfterAddLiquidity = hook.balanceOf(address(this));
        emit log_uint(pointsBalanceAfterAddLiquidity);

        assertApproxEqAbs(
            pointsBalanceAfterAddLiquidity - pointsBalanceOriginal,
            2995354955910434,
            0.0001 ether // error margin for precision loss
        );

        // Now we swap
        // We will swap 0.001 ether for tokens
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: true,
                settleUsingBurn: false
            }),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(address(this));
        emit log_uint(pointsBalanceAfterSwap);
        assertEq(
            pointsBalanceAfterSwap - pointsBalanceAfterAddLiquidity,
            2 * 10 ** 14
        );
    }

    function test_addLiquidityAndSwapWithReferral() public {
        bytes memory hookData = hook.getHookData(address(1), address(this));

        uint256 pointsBalanceOriginal = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceOriginal = hook.balanceOf(address(1));
        emit log_uint(pointsBalanceOriginal);
        emit log_uint(referrerPointsBalanceOriginal);

        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: 0
            }),
            hookData
        );

        uint256 pointsBalanceAfterAddLiquidity = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceAfterAddLiquidity = hook.balanceOf(
            address(1)
        );
        emit log_uint(pointsBalanceAfterAddLiquidity);
        emit log_uint(referrerPointsBalanceAfterAddLiquidity);

        assertApproxEqAbs(
            pointsBalanceAfterAddLiquidity - pointsBalanceOriginal,
            2995354955910434,
            0.00001 ether
        );
        assertApproxEqAbs(
            referrerPointsBalanceAfterAddLiquidity -
                referrerPointsBalanceOriginal -
                hook.POINTS_FOR_REFERRAL(),
            299535495591043,
            0.000001 ether
        );

        // Now we swap
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: true,
                settleUsingBurn: false
            }),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceAfterSwap = hook.balanceOf(address(1));
        emit log_uint(pointsBalanceAfterSwap);
        emit log_uint(referrerPointsBalanceAfterSwap);

        assertEq(
            pointsBalanceAfterSwap - pointsBalanceAfterAddLiquidity,
            2 * 10 ** 14
        );
        assertEq(
            referrerPointsBalanceAfterSwap -
                referrerPointsBalanceAfterAddLiquidity,
            2 * 10 ** 13
        );
    }

    function test_lockUpPeriod() public {
        bytes memory hookData = hook.getHookData(address(0), address(this));

        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: 0
            }),
            hookData
        );

        // Attempt to remove liquidity before the lock-up period ends
        vm.expectRevert("Liquidity is still locked");
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -1 ether,
                salt: 0
            }),
            hookData
        );

        // Warp forward in time to surpass the lock-up period
        vm.warp(block.timestamp + hook.MINIMUM_LOCKUP_TIME() + 1);

        // Now attempt to remove liquidity after the lock-up period ends
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -1 ether,
                salt: 0
            }),
            hookData
        );
    }

    // function test_addLiquidityWithoutNFT() public {
    //     bytes memory hookData = hook.getHookData(address(0), address(this));

    //     vm.expectRevert("MissingLiquidityLicense");
    //     modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
    //         key,
    //         IPoolManager.ModifyLiquidityParams({
    //             tickLower: -60,
    //             tickUpper: 60,
    //             liquidityDelta: 1 ether,
    //             salt: 0
    //         }),
    //         hookData
    //     );
    // }

    // function test_addLiquidityWithNFT() public {
    //     bytes memory hookData = hook.getHookData(address(0), address(this));
    //     loyaltyCredentials.mintLiquidityLicense(address(this)); // Mint the required liquidity NFT
    //     // loyaltyCredentials.mintTradingCredential(address(this)); // Mint the required trading NFT

    //     modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
    //         key,
    //         IPoolManager.ModifyLiquidityParams({
    //             tickLower: -60,
    //             tickUpper: 60,
    //             liquidityDelta: 1 ether,
    //             salt: 0
    //         }),
    //         hookData
    //     );

    //     uint256 pointsBalanceAfterAddLiquidity = hook.balanceOf(address(this));
    //     assert(pointsBalanceAfterAddLiquidity > 0);
    // }
}
