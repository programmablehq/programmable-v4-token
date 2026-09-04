// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { ActionConstants } from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IProgrammableLaunchToken is IERC20 {
    function totalSupply() external view returns (uint256);
    function FIXED_SUPPLY() external view returns (uint256);
    function INITIAL_HOLDER() external view returns (address);
    function INITIAL_LIQUIDITY_HOLDER() external view returns (address);
    function INITIAL_LIQUIDITY_BUDGET() external view returns (uint256);
}

interface IProgrammableLaunchFeeHookView {
    function poolManager() external view returns (IPoolManager);
    function LAUNCH_FEE_PIPS() external view returns (uint24);
    function PERMANENT_FEE_PIPS() external view returns (uint24);
    function LAUNCH_FEE_DURATION() external view returns (uint64);
    function TOKEN() external view returns (address);
    function AUTHORIZED_INITIALIZER() external view returns (address);
    function TICK_SPACING() external view returns (int24);
    function INITIAL_SQRT_PRICE_X96() external view returns (uint160);
    function canonicalPoolId() external view returns (bytes32);
    function poolInitialized() external view returns (bool);
    function firstSwapTimestamp() external view returns (uint64);
    function feeEndTimestamp() external view returns (uint64);
}

/// @title Programmable Atomic Launch Initializer
/// @notice One-shot graph target that initializes the canonical pool, mints its unlocked LP NFT, and performs the
///         protected initial buy in one transaction.
/// @dev This contract has no owner, upgrade path, rescue function, allowance, or reusable execution surface.
contract ProgrammableLaunchInitializer is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant DEPLOYMENT_CHAIN_ID = 4663;
    address public constant LAUNCH_WALLET = 0x245099E77F8F0Cad9a75B1B56db8FDE7C948d5B1;
    address public constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant ROBINHOOD_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    uint256 public constant FIXED_SUPPLY = 1_000_000_000 ether;
    uint256 public constant INITIAL_LIQUIDITY_TOKEN_BUDGET = 50_000_000 ether;
    uint256 public constant INITIAL_WALLET_ALLOCATION = FIXED_SUPPLY - INITIAL_LIQUIDITY_TOKEN_BUDGET;
    int24 public constant TICK_SPACING = 60;
    uint24 private constant EXPECTED_LAUNCH_FEE_PIPS = 300_000;
    uint24 private constant EXPECTED_PERMANENT_FEE_PIPS = 10_000;
    uint64 private constant EXPECTED_LAUNCH_FEE_DURATION = 30;
    // Keep the launch transaction bounded by the Router's one-hour permit while
    // allowing an authoritative finalized-state simulation on Robinhood Chain.
    uint256 public constant MAX_DEADLINE_DELAY = 1 hours;
    uint160 public constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
    uint160 public constant HOOK_FLAGS_MASK = (1 << 14) - 1;

    enum Phase {
        Uninitialized,
        Active,
        Complete
    }

    struct LaunchParameters {
        uint160 initialSqrtPriceX96;
        uint160 initialBuySqrtPriceLimitX96;
        uint128 lpNativeBudget;
        uint128 initialBuyNativeAmount;
        uint128 minimumInitialBuyTokenOut;
        uint256 deadline;
    }

    struct LiquidityPlan {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 nativeAmount;
        uint128 tokenAmount;
    }

    struct BuyContext {
        uint128 nativeAmount;
        uint128 minimumTokenOut;
        uint160 sqrtPriceLimitX96;
    }

    address public immutable GRAPH_DEPLOYER;
    bytes32 public immutable EXPECTED_GRAPH_DEPLOYER_RUNTIME_CODE_HASH;
    bytes32 public immutable EXPECTED_POOL_MANAGER_RUNTIME_CODE_HASH;
    bytes32 public immutable EXPECTED_POSITION_MANAGER_RUNTIME_CODE_HASH;
    /// @dev Exact callback-authority alias used only by the first-effect authentication guard.
    address private constant poolManager = ROBINHOOD_POOL_MANAGER;

    Phase public phase;
    address public token;
    address public hook;
    bytes32 public poolId;
    bytes32 public tokenRuntimeCodeHash;
    bytes32 public hookRuntimeCodeHash;
    bytes32 private activeBuyContextHash;
    uint256 public lpTokenId;
    uint128 public lpLiquidity;
    uint128 public lpNativeAmount;
    uint128 public lpTokenAmount;
    uint128 public initialBuyNativeAmount;
    uint128 public initialBuyTokenAmount;

    error WrongChain(uint256 actualChainId);
    error ZeroAddress();
    error ZeroCodeHash();
    error UnauthorizedDeploymentFactory(address caller, address expected);
    error RuntimeCodeHashMismatch(address target, bytes32 actual, bytes32 expected);
    error UnauthorizedGraphDeployer(address caller);
    error InvalidPhase(Phase actual, Phase expected);
    error InvalidTokenConfiguration();
    error InvalidHookConfiguration();
    error InvalidHookFlags(uint160 actual, uint160 expected);
    error InvalidLaunchParameters();
    error InvalidDeadline(uint256 deadline, uint256 currentTimestamp);
    error InvalidInitialBuyPriceLimit();
    error InvalidFunding(uint256 actual, uint256 expected);
    error InvalidLiquidityPlan();
    error PoolInitializationMismatch(int24 actualTick, int24 expectedTick);
    error InvalidPositionManagerPoolManager(address actual, address expected);
    error PositionManagerBalanceChanged();
    error PositionTokenIdMismatch(uint256 positionTokenId, uint256 nextTokenId);
    error PositionOwnershipMismatch(uint256 tokenId, address actualOwner);
    error PositionLiquidityMismatch(uint256 tokenId, uint128 actual, uint128 expected);
    error LiquidityTokenRemainderMismatch(uint256 actual, uint256 expected);
    error UnauthorizedPoolManager(address caller);
    error InvalidBuyContext();
    error InvalidInitialBuyDelta(int128 amount0, int128 amount1);
    error PartialInitialBuy(uint128 actual, uint128 expected);
    error InitialBuySlippage(uint128 actual, uint128 minimum);
    error NativeSettlementMismatch(uint256 actual, uint256 expected);
    error LaunchAccountingMismatch();

    event LaunchCompleted(
        address indexed token,
        address indexed hook,
        bytes32 indexed poolId,
        uint256 lpTokenId,
        uint128 lpLiquidity,
        uint128 lpNativeAmount,
        uint128 lpTokenAmount,
        uint128 initialBuyNativeAmount,
        uint128 initialBuyTokenAmount
    );

    constructor(
        address graphDeployer,
        bytes32 expectedGraphDeployerRuntimeCodeHash,
        bytes32 expectedPoolManagerRuntimeCodeHash,
        bytes32 expectedPositionManagerRuntimeCodeHash
    ) {
        if (block.chainid != DEPLOYMENT_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }
        if (graphDeployer == address(0)) revert ZeroAddress();
        if (
            expectedGraphDeployerRuntimeCodeHash == bytes32(0) || expectedPoolManagerRuntimeCodeHash == bytes32(0)
                || expectedPositionManagerRuntimeCodeHash == bytes32(0)
        ) revert ZeroCodeHash();
        if (msg.sender != graphDeployer) revert UnauthorizedDeploymentFactory(msg.sender, graphDeployer);

        GRAPH_DEPLOYER = graphDeployer;
        EXPECTED_GRAPH_DEPLOYER_RUNTIME_CODE_HASH = expectedGraphDeployerRuntimeCodeHash;
        EXPECTED_POOL_MANAGER_RUNTIME_CODE_HASH = expectedPoolManagerRuntimeCodeHash;
        EXPECTED_POSITION_MANAGER_RUNTIME_CODE_HASH = expectedPositionManagerRuntimeCodeHash;

        _requireRuntimeCodeHash(graphDeployer, expectedGraphDeployerRuntimeCodeHash);
        _requireRuntimeCodeHash(ROBINHOOD_POOL_MANAGER, expectedPoolManagerRuntimeCodeHash);
        _requireRuntimeCodeHash(ROBINHOOD_POSITION_MANAGER, expectedPositionManagerRuntimeCodeHash);
    }

    /// @notice Executes the complete launch once. The graph must supply exactly the computed LP native amount plus buy.
    function initialize(
        address token_,
        address hook_,
        bytes32 expectedTokenRuntimeCodeHash,
        bytes32 expectedHookRuntimeCodeHash,
        LaunchParameters calldata parameters
    ) external payable returns (uint256 positionTokenId, uint128 liquidity, uint128 boughtTokens) {
        if (msg.sender != GRAPH_DEPLOYER) revert UnauthorizedGraphDeployer(msg.sender);
        if (phase != Phase.Uninitialized) revert InvalidPhase(phase, Phase.Uninitialized);
        phase = Phase.Active;

        _validateInfrastructure();
        _validateLaunchParameters(parameters);
        _validateTokenAndHook(
            token_, hook_, expectedTokenRuntimeCodeHash, expectedHookRuntimeCodeHash, parameters.initialSqrtPriceX96
        );

        token = token_;
        hook = hook_;
        tokenRuntimeCodeHash = expectedTokenRuntimeCodeHash;
        hookRuntimeCodeHash = expectedHookRuntimeCodeHash;

        PoolKey memory key = _poolKey(token_, hook_);
        poolId = PoolId.unwrap(key.toId());
        if (IProgrammableLaunchFeeHookView(hook_).canonicalPoolId() != poolId) revert InvalidHookConfiguration();

        return _executeLaunch(parameters);
    }

    function _executeLaunch(LaunchParameters calldata parameters)
        private
        returns (uint256 positionTokenId, uint128 liquidity, uint128 boughtTokens)
    {
        PoolKey memory key = _poolKey(token, hook);
        LiquidityPlan memory plan = previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 requiredValue = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        if (msg.value != requiredValue) revert InvalidFunding(msg.value, requiredValue);
        uint256 forcedNativeBalance = address(this).balance - msg.value;

        int24 initializedTick = IPoolManager(ROBINHOOD_POOL_MANAGER).initialize(key, parameters.initialSqrtPriceX96);
        int24 expectedTick = TickMath.getTickAtSqrtPrice(parameters.initialSqrtPriceX96);
        if (initializedTick != expectedTick) revert PoolInitializationMismatch(initializedTick, expectedTick);

        positionTokenId = _mintInitialPosition(key, plan, parameters.deadline);
        liquidity = plan.liquidity;
        uint256 tokenRemainder = _returnLiquidityTokenRemainder(plan.tokenAmount);

        boughtTokens = _executeInitialBuy(
            BuyContext({
                nativeAmount: parameters.initialBuyNativeAmount,
                minimumTokenOut: parameters.minimumInitialBuyTokenOut,
                sqrtPriceLimitX96: parameters.initialBuySqrtPriceLimitX96
            })
        );

        _verifyFinalAccounting(tokenRemainder, boughtTokens, forcedNativeBalance);

        _recordCompletedLaunch(plan, positionTokenId, parameters.initialBuyNativeAmount, boughtTokens);
    }

    function _recordCompletedLaunch(
        LiquidityPlan memory plan,
        uint256 positionTokenId,
        uint128 buyNativeAmount,
        uint128 boughtTokens
    ) private {
        lpTokenId = positionTokenId;
        lpLiquidity = plan.liquidity;
        lpNativeAmount = plan.nativeAmount;
        lpTokenAmount = plan.tokenAmount;
        initialBuyNativeAmount = buyNativeAmount;
        initialBuyTokenAmount = boughtTokens;
        phase = Phase.Complete;

        emit LaunchCompleted(
            token,
            hook,
            poolId,
            positionTokenId,
            plan.liquidity,
            plan.nativeAmount,
            plan.tokenAmount,
            buyNativeAmount,
            boughtTokens
        );
    }

    function _returnLiquidityTokenRemainder(uint128 usedTokenAmount) private returns (uint256 remainder) {
        remainder = INITIAL_LIQUIDITY_TOKEN_BUDGET - uint256(usedTokenAmount);
        uint256 actualRemainder = IERC20(token).balanceOf(address(this));
        if (actualRemainder != remainder) revert LiquidityTokenRemainderMismatch(actualRemainder, remainder);
        if (remainder != 0) IERC20(token).safeTransfer(LAUNCH_WALLET, remainder);
    }

    function _verifyFinalAccounting(uint256 tokenRemainder, uint128 boughtTokens, uint256 forcedNativeBalance)
        private
        view
    {
        uint256 expectedWalletBalance = INITIAL_WALLET_ALLOCATION + tokenRemainder + uint256(boughtTokens);
        if (
            IERC20(token).balanceOf(LAUNCH_WALLET) != expectedWalletBalance
                || IERC20(token).balanceOf(address(this)) != 0 || address(this).balance != forcedNativeBalance
                || IProgrammableLaunchToken(token).totalSupply() != FIXED_SUPPLY
        ) revert LaunchAccountingMismatch();

        if (block.timestamp > type(uint64).max - EXPECTED_LAUNCH_FEE_DURATION) revert LaunchAccountingMismatch();
        uint64 expectedFeeEnd = uint64(block.timestamp) + EXPECTED_LAUNCH_FEE_DURATION;
        if (
            IProgrammableLaunchFeeHookView(hook).firstSwapTimestamp() != uint64(block.timestamp)
                || IProgrammableLaunchFeeHookView(hook).feeEndTimestamp() != expectedFeeEnd
        ) revert LaunchAccountingMismatch();
    }

    /// @notice Computes the exact full-range position principal from the signed price and native budget.
    function previewLiquidity(uint160 initialSqrtPriceX96, uint128 lpNativeBudget)
        public
        pure
        returns (LiquidityPlan memory plan)
    {
        if (
            initialSqrtPriceX96 < TickMath.MIN_SQRT_PRICE || initialSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
                || lpNativeBudget == 0
        ) revert InvalidLaunchParameters();

        plan.tickLower = TickMath.minUsableTick(TICK_SPACING);
        plan.tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(plan.tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(plan.tickUpper);
        plan.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, lpNativeBudget, INITIAL_LIQUIDITY_TOKEN_BUDGET
        );
        if (plan.liquidity == 0 || plan.liquidity > Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING)) {
            revert InvalidLiquidityPlan();
        }

        uint256 nativeAmount =
            SqrtPriceMath.getAmount0Delta(initialSqrtPriceX96, sqrtPriceUpperX96, plan.liquidity, true);
        uint256 tokenAmount =
            SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, initialSqrtPriceX96, plan.liquidity, true);
        if (
            nativeAmount == 0 || tokenAmount == 0 || nativeAmount > lpNativeBudget
                || tokenAmount > INITIAL_LIQUIDITY_TOKEN_BUDGET || nativeAmount > type(uint128).max
                || tokenAmount > type(uint128).max
        ) revert InvalidLiquidityPlan();

        plan.nativeAmount = uint128(nativeAmount);
        plan.tokenAmount = uint128(tokenAmount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert UnauthorizedPoolManager(msg.sender);
        if (phase != Phase.Active) revert InvalidPhase(phase, Phase.Active);
        if (activeBuyContextHash == bytes32(0) || keccak256(data) != activeBuyContextHash) revert InvalidBuyContext();

        BuyContext memory context = abi.decode(data, (BuyContext));
        PoolKey memory key = _poolKey(token, hook);
        BalanceDelta delta = IPoolManager(ROBINHOOD_POOL_MANAGER)
            .swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(uint256(context.nativeAmount)),
                    sqrtPriceLimitX96: context.sqrtPriceLimitX96
                }),
                bytes("")
            );

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        if (amount0 >= 0 || amount1 <= 0) revert InvalidInitialBuyDelta(amount0, amount1);
        uint128 spentNative = uint128(-amount0);
        uint128 boughtTokens = uint128(amount1);
        if (spentNative != context.nativeAmount) revert PartialInitialBuy(spentNative, context.nativeAmount);
        if (boughtTokens < context.minimumTokenOut) {
            revert InitialBuySlippage(boughtTokens, context.minimumTokenOut);
        }

        uint256 paid = IPoolManager(ROBINHOOD_POOL_MANAGER).settle{ value: spentNative }();
        if (paid != spentNative) revert NativeSettlementMismatch(paid, spentNative);
        IPoolManager(ROBINHOOD_POOL_MANAGER).take(Currency.wrap(token), LAUNCH_WALLET, boughtTokens);
        return abi.encode(boughtTokens);
    }

    function _mintInitialPosition(PoolKey memory key, LiquidityPlan memory plan, uint256 deadline)
        private
        returns (uint256 positionTokenId)
    {
        IPositionManager positionManager = IPositionManager(ROBINHOOD_POSITION_MANAGER);
        uint256 nativeBalanceBefore = ROBINHOOD_POSITION_MANAGER.balance;
        uint256 tokenBalanceBefore = IERC20(token).balanceOf(ROBINHOOD_POSITION_MANAGER);
        positionTokenId = positionManager.nextTokenId();

        IERC20(token).safeTransfer(ROBINHOOD_POSITION_MANAGER, plan.tokenAmount);

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)), bytes1(uint8(Actions.SETTLE)), bytes1(uint8(Actions.SETTLE))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            plan.tickLower,
            plan.tickUpper,
            uint256(plan.liquidity),
            plan.nativeAmount,
            plan.tokenAmount,
            LAUNCH_WALLET,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, uint256(ActionConstants.OPEN_DELTA), false);
        params[2] = abi.encode(key.currency1, uint256(ActionConstants.OPEN_DELTA), false);

        positionManager.modifyLiquidities{ value: plan.nativeAmount }(abi.encode(actions, params), deadline);

        uint256 nextTokenId = positionManager.nextTokenId();
        if (positionTokenId == type(uint256).max || nextTokenId != positionTokenId + 1) {
            revert PositionTokenIdMismatch(positionTokenId, nextTokenId);
        }
        if (
            ROBINHOOD_POSITION_MANAGER.balance != nativeBalanceBefore
                || IERC20(token).balanceOf(ROBINHOOD_POSITION_MANAGER) != tokenBalanceBefore
        ) revert PositionManagerBalanceChanged();
        address actualOwner = IERC721(ROBINHOOD_POSITION_MANAGER).ownerOf(positionTokenId);
        if (actualOwner != LAUNCH_WALLET) revert PositionOwnershipMismatch(positionTokenId, actualOwner);
        uint128 actualLiquidity = positionManager.getPositionLiquidity(positionTokenId);
        if (actualLiquidity != plan.liquidity) {
            revert PositionLiquidityMismatch(positionTokenId, actualLiquidity, plan.liquidity);
        }
    }

    function _executeInitialBuy(BuyContext memory context) private returns (uint128 boughtTokens) {
        bytes memory data = abi.encode(context);
        activeBuyContextHash = keccak256(data);
        bytes memory result = IPoolManager(ROBINHOOD_POOL_MANAGER).unlock(data);
        activeBuyContextHash = bytes32(0);
        boughtTokens = abi.decode(result, (uint128));
    }

    function _validateInfrastructure() private view {
        _requireRuntimeCodeHash(GRAPH_DEPLOYER, EXPECTED_GRAPH_DEPLOYER_RUNTIME_CODE_HASH);
        _requireRuntimeCodeHash(ROBINHOOD_POOL_MANAGER, EXPECTED_POOL_MANAGER_RUNTIME_CODE_HASH);
        _requireRuntimeCodeHash(ROBINHOOD_POSITION_MANAGER, EXPECTED_POSITION_MANAGER_RUNTIME_CODE_HASH);

        address positionManagerPoolManager = address(IPositionManager(ROBINHOOD_POSITION_MANAGER).poolManager());
        if (positionManagerPoolManager != ROBINHOOD_POOL_MANAGER) {
            revert InvalidPositionManagerPoolManager(positionManagerPoolManager, ROBINHOOD_POOL_MANAGER);
        }
    }

    function _validateLaunchParameters(LaunchParameters calldata parameters) private view {
        if (
            parameters.initialSqrtPriceX96 < TickMath.MIN_SQRT_PRICE
                || parameters.initialSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE || parameters.lpNativeBudget == 0
                || parameters.initialBuyNativeAmount == 0 || parameters.minimumInitialBuyTokenOut == 0
                || parameters.initialBuyNativeAmount > uint128(type(int128).max)
        ) revert InvalidLaunchParameters();
        if (parameters.deadline < block.timestamp || parameters.deadline > block.timestamp + MAX_DEADLINE_DELAY) {
            revert InvalidDeadline(parameters.deadline, block.timestamp);
        }
        if (
            parameters.initialBuySqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE
                || parameters.initialBuySqrtPriceLimitX96 >= parameters.initialSqrtPriceX96
        ) revert InvalidInitialBuyPriceLimit();
    }

    function _validateTokenAndHook(
        address token_,
        address hook_,
        bytes32 expectedTokenRuntimeCodeHash,
        bytes32 expectedHookRuntimeCodeHash,
        uint160 initialSqrtPriceX96
    ) private view {
        if (token_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        if (expectedTokenRuntimeCodeHash == bytes32(0) || expectedHookRuntimeCodeHash == bytes32(0)) {
            revert ZeroCodeHash();
        }
        _requireRuntimeCodeHash(token_, expectedTokenRuntimeCodeHash);
        _requireRuntimeCodeHash(hook_, expectedHookRuntimeCodeHash);

        IProgrammableLaunchToken launchToken = IProgrammableLaunchToken(token_);
        if (
            launchToken.FIXED_SUPPLY() != FIXED_SUPPLY
                || launchToken.INITIAL_LIQUIDITY_BUDGET() != INITIAL_LIQUIDITY_TOKEN_BUDGET
                || launchToken.INITIAL_HOLDER() != LAUNCH_WALLET
                || launchToken.INITIAL_LIQUIDITY_HOLDER() != address(this) || launchToken.totalSupply() != FIXED_SUPPLY
                || launchToken.balanceOf(LAUNCH_WALLET) != INITIAL_WALLET_ALLOCATION
                || launchToken.balanceOf(address(this)) != INITIAL_LIQUIDITY_TOKEN_BUDGET
        ) revert InvalidTokenConfiguration();

        uint160 actualFlags = uint160(hook_) & HOOK_FLAGS_MASK;
        if (actualFlags != REQUIRED_HOOK_FLAGS) revert InvalidHookFlags(actualFlags, REQUIRED_HOOK_FLAGS);
        IProgrammableLaunchFeeHookView launchHook = IProgrammableLaunchFeeHookView(hook_);
        if (
            address(launchHook.poolManager()) != ROBINHOOD_POOL_MANAGER
                || launchHook.LAUNCH_FEE_PIPS() != EXPECTED_LAUNCH_FEE_PIPS
                || launchHook.PERMANENT_FEE_PIPS() != EXPECTED_PERMANENT_FEE_PIPS
                || launchHook.LAUNCH_FEE_DURATION() != EXPECTED_LAUNCH_FEE_DURATION || launchHook.TOKEN() != token_
                || launchHook.AUTHORIZED_INITIALIZER() != address(this) || launchHook.TICK_SPACING() != TICK_SPACING
                || launchHook.INITIAL_SQRT_PRICE_X96() != initialSqrtPriceX96 || launchHook.poolInitialized()
                || launchHook.firstSwapTimestamp() != 0 || launchHook.feeEndTimestamp() != 0
        ) revert InvalidHookConfiguration();
    }

    function _poolKey(address token_, address hook_) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token_),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook_)
        });
    }

    function _requireRuntimeCodeHash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert RuntimeCodeHashMismatch(target, actual, expected);
    }
}
