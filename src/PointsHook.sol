// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

// Added for Credentials NFT
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";


contract PointsHook is BaseHook, ERC20 {
    error MissingLiquidityLicense();
    error MissingTradingCredentials();
    error NotPoolOperator();

    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    mapping(address => address) public referredBy;

    // **** added to track time stamp of when liquidity is added
    mapping(address => uint256) public liquidityAddedTimestamp;

    // **** added for NFT credentials
    IERC1155 immutable loyaltyCredentials;
    address allowedPoolOperator;

    /// Liquidity License allows to perform modifyPosition operations while Trading Credentials allow to swap
    uint256 public constant LIQUIDITY_LICENSE = 1;
    uint256 public constant TRADING_CREDENTIAL = 2;

    // **** added for minimum lock-up period
    uint256 public constant MINIMUM_LOCKUP_TIME = 7 days; 
    uint256 public constant POINTS_FOR_REFERRAL = 500 * 10 ** 18;

    constructor(
        IPoolManager _manager,
        string memory _name,
        string memory _symbol
        // address _loyaltyCredentials,
        // address _allowedPoolOperator
    ) BaseHook(_manager) ERC20(_name, _symbol, 18) {
        // allowedPoolOperator = _allowedPoolOperator;
        // loyaltyCredentials = IERC1155(_loyaltyCredentials);
        }
    
    /// ensure it is only the qualified PoolOperator
    // modifier poolOperatorOnly(address sender) {
    //     if (sender != address(allowedPoolOperator)) revert NotPoolOperator();
    //     _;
    // }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                // to-do> for role-based permissions to change beforeAddLiquidity to true
                beforeAddLiquidity: false,
                // added hook permissions for before removing liquidity
                beforeRemoveLiquidity: true,
                afterAddLiquidity: true,
                afterRemoveLiquidity: false,
                // to do> added hook permissions for needing the trading license to trade to true
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // added a beforeSwap for the trading credentials check

    // function beforeSwap(
    //     address sender,
    //     PoolKey calldata,
    //     IPoolManager.SwapParams calldata,
    //     bytes calldata hookData
    // ) external view override returns (bytes4) {
    //     if (sender != allowedPoolOperator) {
    //         revert NotPoolOperator();
    //     }

    //     address user = _getUserAddress(hookData);

    //     if (loyaltyCredentials.balanceOf(user, TRADING_CREDENTIAL) == 0) {
    //         revert MissingTradingCredentials();
    //     }
    // }

    // // added a beforeAddLiquidity for the liquidity licensing credentials check

    // function beforeAddLiquidity(
    //     address sender,
    //     PoolKey calldata,
    //     IPoolManager.ModifyLiquidityParams calldata,
    //     bytes calldata hookData
    // ) external view override returns (bytes4) {
    //     if (sender != allowedPoolOperator) {
    //         revert NotPoolOperator();
    //     }

    //     address user = _getUserAddress(hookData);

    //     if (loyaltyCredentials.balanceOf(user, LIQUIDITY_LICENSE) == 0) {
    //         revert MissingLiquidityLicense();
    //     }
    // }

    // function _getUserAddress(
    //     bytes calldata hookData
    // ) internal pure returns (address user) {
    //     user = abi.decode(hookData, (address));
    // }

    // points functions

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, int128) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isNative()) return (this.afterSwap.selector, 0);

        // We only mint points if user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        // Mint points equal to 20% of the amount of ETH they spent
        // Since its a zeroForOne swap:
        // if amountSpecified < 0:
        //      this is an "exact input for output" swap
        //      amount of ETH they spent is equal to |amountSpecified|
        // if amountSpecified > 0:
        //      this is an "exact output for input" swap
        //      amount of ETH they spent is equal to BalanceDelta.amount0()

        uint256 ethSpendAmount = swapParams.amountSpecified < 0
            ? uint256(-swapParams.amountSpecified)
            : uint256(int256(-delta.amount0()));
        uint256 pointsForSwap = ethSpendAmount / 5;

        // Mint the points including any referral points
        _assignPoints(hookData, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isNative()) return (this.afterSwap.selector, delta);

        // Mint points equivalent to how much ETH they're adding in liquidity
        uint256 pointsForAddingLiquidity = uint256(int256(-delta.amount0()));

        // Store the timestamp when liquidity is added
        liquidityAddedTimestamp[msg.sender] = block.timestamp;

        // Mint the points including any referral points
        _assignPoints(hookData, pointsForAddingLiquidity);

        return (this.afterAddLiquidity.selector, delta);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        // Check if the lock-up period has elapsed
        require(
            block.timestamp >= liquidityAddedTimestamp[sender] + MINIMUM_LOCKUP_TIME,
            "Liquidity is still locked"
        );
        return this.beforeRemoveLiquidity.selector;
    }

    function _assignPoints(
        bytes calldata hookData,
        uint256 referreePoints
    ) internal {
        if (hookData.length == 0) return;

        (address referrer, address referree) = abi.decode(
            hookData,
            (address, address)
        );
        if (referree == address(0)) return;

        if (referredBy[referree] == address(0) && referrer != address(0)) {
            referredBy[referree] = referrer;
            _mint(referrer, POINTS_FOR_REFERRAL);
        }

        // Mint 10% of the referree's points to the referrer
        if (referredBy[referree] != address(0)) {
            _mint(referrer, referreePoints / 10);
        }

        _mint(referree, referreePoints);
    }

    function getHookData(
        address referrer,
        address referree
    ) public pure returns (bytes memory) {
        return abi.encode(referrer, referree);
    }
}
