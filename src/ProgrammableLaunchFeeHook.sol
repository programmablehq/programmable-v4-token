// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Programmable Launch Fee Hook
/// @notice Protects the one canonical native-ETH/V4 pool initialization and applies its immutable fee schedule.
/// @dev The first successful canonical swap starts a 30-second 30% LP-fee window. The LP fee is 1% thereafter.
contract ProgrammableLaunchFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    uint256 public constant DEPLOYMENT_CHAIN_ID = 4663;
    address public constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint24 public constant LAUNCH_FEE_PIPS = 300_000;
    uint24 public constant PERMANENT_FEE_PIPS = 10_000;
    uint64 public constant LAUNCH_FEE_DURATION = 30;

    address public immutable TOKEN;
    address public immutable AUTHORIZED_INITIALIZER;
    int24 public immutable TICK_SPACING;
    uint160 public immutable INITIAL_SQRT_PRICE_X96;
    bytes32 public immutable canonicalPoolId;

    bool public poolInitialized;
    uint64 public firstSwapTimestamp;

    error WrongChain(uint256 actualChainId);
    error ZeroToken();
    error ZeroInitializer();
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidInitialSqrtPrice(uint160 sqrtPriceX96);
    error UnauthorizedInitializer();
    error InvalidPoolKey();
    error InvalidInitialPrice();
    error AlreadyInitialized();
    error PoolNotInitialized();
    error UnexpectedPool();
    error UnauthorizedFirstSwap(address sender);
    error TimestampOverflow();

    event PoolInitializationAuthorized(bytes32 indexed poolId, uint160 sqrtPriceX96);
    event LaunchFeeWindowStarted(bytes32 indexed poolId, uint64 firstSwapTimestamp, uint64 feeEndTimestamp);

    constructor(address token, address authorizedInitializer, int24 tickSpacing, uint160 initialSqrtPriceX96)
        BaseHook(IPoolManager(ROBINHOOD_POOL_MANAGER))
    {
        if (block.chainid != DEPLOYMENT_CHAIN_ID) revert WrongChain(block.chainid);
        if (token == address(0)) revert ZeroToken();
        if (authorizedInitializer == address(0)) revert ZeroInitializer();
        if (tickSpacing < TickMath.MIN_TICK_SPACING || tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing(tickSpacing);
        }
        if (initialSqrtPriceX96 < TickMath.MIN_SQRT_PRICE || initialSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidInitialSqrtPrice(initialSqrtPriceX96);
        }

        TOKEN = token;
        AUTHORIZED_INITIALIZER = authorizedInitializer;
        TICK_SPACING = tickSpacing;
        INITIAL_SQRT_PRICE_X96 = initialSqrtPriceX96;

        PoolKey memory canonicalKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
        canonicalPoolId = PoolId.unwrap(canonicalKey.toId());
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Returns the LP fee that a canonical swap would receive in the current block.
    function currentLPFeePips() public view returns (uint24) {
        uint64 endTimestamp = feeEndTimestamp();
        if (endTimestamp == 0 || block.timestamp < endTimestamp) return LAUNCH_FEE_PIPS;
        return PERMANENT_FEE_PIPS;
    }

    /// @notice Returns when the immutable 30% launch-fee window ends.
    /// @dev Derived from the one-shot start timestamp; no separate mutable fee state exists.
    function feeEndTimestamp() public view returns (uint64) {
        uint64 startTimestamp = firstSwapTimestamp;
        if (startTimestamp == 0) return 0;
        return startTimestamp + LAUNCH_FEE_DURATION;
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (sender != AUTHORIZED_INITIALIZER) revert UnauthorizedInitializer();
        if (PoolId.unwrap(key.toId()) != canonicalPoolId) revert InvalidPoolKey();
        if (sqrtPriceX96 != INITIAL_SQRT_PRICE_X96) revert InvalidInitialPrice();
        if (poolInitialized) revert AlreadyInitialized();

        poolInitialized = true;
        emit PoolInitializationAuthorized(canonicalPoolId, sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != canonicalPoolId) revert UnexpectedPool();
        if (!poolInitialized) revert PoolNotInitialized();

        if (firstSwapTimestamp == 0) {
            if (sender != AUTHORIZED_INITIALIZER) revert UnauthorizedFirstSwap(sender);
            if (block.timestamp > type(uint64).max - LAUNCH_FEE_DURATION) revert TimestampOverflow();
            uint64 startTimestamp = uint64(block.timestamp);
            uint64 endTimestamp = startTimestamp + LAUNCH_FEE_DURATION;
            firstSwapTimestamp = startTimestamp;
            emit LaunchFeeWindowStarted(canonicalPoolId, startTimestamp, endTimestamp);
        }

        uint24 feeWithOverride = currentLPFeePips() | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithOverride);
    }
}
