// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Test, Vm } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ProgrammableLaunchFeeHook } from "../src/ProgrammableLaunchFeeHook.sol";
import { ProgrammableLaunchInitializer } from "../src/ProgrammableLaunchInitializer.sol";
import { ProgrammableToken } from "../src/ProgrammableToken.sol";

contract ProgrammableLaunchInitializerTest is Test {
    address internal constant LAUNCH_WALLET = 0x245099E77F8F0Cad9a75B1B56db8FDE7C948d5B1;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    uint160 internal constant INITIAL_PRICE = 1 << 96;
    uint160 internal constant EXPECTED_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    GraphFactoryHarness internal graphFactory;
    PositionManagerHarness internal positionManager;
    ProgrammableLaunchInitializer internal initializer;
    ProgrammableToken internal token;
    ProgrammableLaunchFeeHook internal hook;
    IPoolManager internal manager;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_000_000);
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), POOL_MANAGER);
        manager = IPoolManager(POOL_MANAGER);

        PositionManagerHarness implementation = new PositionManagerHarness();
        vm.etch(POSITION_MANAGER, address(implementation).code);
        positionManager = PositionManagerHarness(payable(POSITION_MANAGER));
        positionManager.configure();

        graphFactory = new GraphFactoryHarness();
        initializer = graphFactory.deployInitializer(POOL_MANAGER.codehash, POSITION_MANAGER.codehash);
        token = new ProgrammableToken(address(initializer));

        bytes memory constructorArgs = abi.encode(address(token), address(initializer), int24(60), INITIAL_PRICE);
        (address expectedHook, bytes32 salt) = HookMiner.find(
            address(this), EXPECTED_FLAGS, type(ProgrammableLaunchFeeHook).creationCode, constructorArgs
        );
        hook = new ProgrammableLaunchFeeHook{ salt: salt }(address(token), address(initializer), 60, INITIAL_PRICE);
        assertEq(address(hook), expectedHook);
    }

    function testAtomicLaunchMintsUnlockedPositionStartsWindowAndClosesAccounting() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 value = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        uint256 forcedNative = 7;
        vm.deal(address(initializer), forcedNative);
        vm.deal(address(this), value);

        vm.recordLogs();
        (uint256 tokenId, uint128 liquidity, uint128 boughtTokens) = graphFactory.launch{ value: value }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        assertEq(uint8(initializer.phase()), uint8(ProgrammableLaunchInitializer.Phase.Complete));
        assertEq(initializer.token(), address(token));
        assertEq(initializer.hook(), address(hook));
        assertEq(initializer.poolId(), hook.canonicalPoolId());
        assertEq(initializer.lpTokenId(), tokenId);
        assertEq(initializer.lpLiquidity(), liquidity);
        assertEq(initializer.lpNativeAmount(), plan.nativeAmount);
        assertEq(initializer.lpTokenAmount(), plan.tokenAmount);
        assertEq(initializer.initialBuyNativeAmount(), parameters.initialBuyNativeAmount);
        assertEq(initializer.initialBuyTokenAmount(), boughtTokens);
        assertEq(positionManager.ownerOf(tokenId), LAUNCH_WALLET);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        assertEq(positionManager.nextTokenId(), tokenId + 1);
        assertEq(address(initializer).balance, forcedNative);
        assertEq(token.balanceOf(address(initializer)), 0);
        assertEq(token.balanceOf(POSITION_MANAGER), 0);
        assertEq(POSITION_MANAGER.balance, 0);
        assertEq(token.allowance(address(initializer), POSITION_MANAGER), 0);
        assertEq(token.allowance(address(initializer), POOL_MANAGER), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertGt(boughtTokens, parameters.minimumInitialBuyTokenOut);
        assertEq(hook.firstSwapTimestamp(), 1_000_000);
        assertEq(hook.feeEndTimestamp(), 1_000_030);
        assertEq(_lastPoolManagerSwapFee(vm.getRecordedLogs()), 300_000);
    }

    function testLaunchPreservesUnrelatedSharedPositionManagerBalances() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 value = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);

        uint256 unrelatedTokenBalance = 123 ether;
        uint256 unrelatedNativeBalance = 456 wei;
        deal(address(token), POSITION_MANAGER, unrelatedTokenBalance);
        vm.deal(POSITION_MANAGER, unrelatedNativeBalance);
        vm.deal(address(this), value);

        graphFactory.launch{ value: value }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        assertEq(token.balanceOf(POSITION_MANAGER), unrelatedTokenBalance);
        assertEq(POSITION_MANAGER.balance, unrelatedNativeBalance);
    }

    function testInitialBuySlippageRevertsPoolPositionTimerAndTransfers() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        parameters.minimumInitialBuyTokenOut = type(uint128).max;
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 value = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        vm.deal(address(this), value);

        vm.expectPartialRevert(ProgrammableLaunchInitializer.InitialBuySlippage.selector);
        graphFactory.launch{ value: value }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        assertEq(uint8(initializer.phase()), uint8(ProgrammableLaunchInitializer.Phase.Uninitialized));
        assertEq(token.balanceOf(address(initializer)), 50_000_000 ether);
        assertEq(token.balanceOf(LAUNCH_WALLET), 950_000_000 ether);
        assertEq(positionManager.nextTokenId(), 1);
        assertEq(hook.firstSwapTimestamp(), 0);
        assertEq(hook.feeEndTimestamp(), 0);
        assertFalse(hook.poolInitialized());
    }

    function testOnlyGraphFactoryCanLaunch() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableLaunchInitializer.UnauthorizedGraphDeployer.selector, address(this))
        );
        initializer.initialize(
            address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testExactFundingIsRequired() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 required = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        vm.deal(address(this), required - 1);

        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableLaunchInitializer.InvalidFunding.selector, required - 1, required)
        );
        graphFactory.launch{ value: required - 1 }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testStaleAndOverlongDeadlinesRevert() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        parameters.deadline = block.timestamp - 1;
        vm.expectPartialRevert(ProgrammableLaunchInitializer.InvalidDeadline.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        parameters.deadline = block.timestamp + initializer.MAX_DEADLINE_DELAY() + 1;
        vm.expectPartialRevert(ProgrammableLaunchInitializer.InvalidDeadline.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        assertEq(uint8(initializer.phase()), uint8(ProgrammableLaunchInitializer.Phase.Uninitialized));
        assertFalse(hook.poolInitialized());
        assertEq(positionManager.nextTokenId(), 1);
    }

    function testRouterAlignedMaximumDeadlineIsAccepted() public {
        assertEq(initializer.MAX_DEADLINE_DELAY(), 1 hours);
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        parameters.deadline = block.timestamp + initializer.MAX_DEADLINE_DELAY();
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 value = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        vm.deal(address(this), value);

        graphFactory.launch{ value: value }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        assertEq(uint8(initializer.phase()), uint8(ProgrammableLaunchInitializer.Phase.Complete));
    }

    function testWrongSourceBoundCodeHashReverts() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        vm.expectPartialRevert(ProgrammableLaunchInitializer.RuntimeCodeHashMismatch.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), bytes32(uint256(1)), address(hook).codehash, parameters
        );
    }

    function testLaunchRejectsPositionManagerBoundToDifferentPoolManager() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        address wrongPoolManager = makeAddr("wrong pool manager");
        vm.mockCall(
            POSITION_MANAGER,
            abi.encodeWithSelector(PositionManagerHarness.poolManager.selector),
            abi.encode(wrongPoolManager)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammableLaunchInitializer.InvalidPositionManagerPoolManager.selector, wrongPoolManager, POOL_MANAGER
            )
        );
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testLaunchRejectsHookBoundToDifferentPoolManager() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        vm.mockCall(
            address(hook), abi.encodeWithSignature("poolManager()"), abi.encode(makeAddr("wrong hook pool manager"))
        );

        vm.expectRevert(ProgrammableLaunchInitializer.InvalidHookConfiguration.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testLaunchRejectsUnexpectedLaunchFee() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        vm.mockCall(address(hook), abi.encodeWithSignature("LAUNCH_FEE_PIPS()"), abi.encode(uint24(299_999)));

        vm.expectRevert(ProgrammableLaunchInitializer.InvalidHookConfiguration.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testLaunchRejectsUnexpectedPermanentFee() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        vm.mockCall(address(hook), abi.encodeWithSignature("PERMANENT_FEE_PIPS()"), abi.encode(uint24(9999)));

        vm.expectRevert(ProgrammableLaunchInitializer.InvalidHookConfiguration.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testLaunchRejectsUnexpectedLaunchFeeDuration() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        vm.mockCall(address(hook), abi.encodeWithSignature("LAUNCH_FEE_DURATION()"), abi.encode(uint64(31)));

        vm.expectRevert(ProgrammableLaunchInitializer.InvalidHookConfiguration.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testLaunchRejectsHookThatAlreadyInitializedAPool() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        vm.mockCall(address(hook), abi.encodeWithSignature("poolInitialized()"), abi.encode(true));

        vm.expectRevert(ProgrammableLaunchInitializer.InvalidHookConfiguration.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testLaunchRejectsUnexpectedPositionTokenIdAdvance() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 value = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        positionManager.setNextTokenIdIncrement(2);
        vm.deal(address(this), value);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammableLaunchInitializer.PositionTokenIdMismatch.selector, uint256(1), uint256(3)
            )
        );
        graphFactory.launch{ value: value }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testPreviewLiquidityRemainsWithinV4PerTickCeiling() public view {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);

        assertLe(plan.liquidity, Pool.tickSpacingToMaxLiquidityPerTick(60));
    }

    function testInvalidBuyPriceLimitReverts() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        parameters.initialBuySqrtPriceLimitX96 = INITIAL_PRICE;
        vm.expectRevert(ProgrammableLaunchInitializer.InvalidInitialBuyPriceLimit.selector);
        graphFactory.launch(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testSecondLaunchCanNeverRun() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 value = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        vm.deal(address(this), value * 2);
        graphFactory.launch{ value: value }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammableLaunchInitializer.InvalidPhase.selector,
                ProgrammableLaunchInitializer.Phase.Complete,
                ProgrammableLaunchInitializer.Phase.Uninitialized
            )
        );
        graphFactory.launch{ value: value }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );
    }

    function testCallbackCannotBeCalledOutsideAuthenticatedActiveUnlock() public {
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableLaunchInitializer.UnauthorizedPoolManager.selector, address(this))
        );
        initializer.unlockCallback(bytes(""));

        vm.prank(POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammableLaunchInitializer.InvalidPhase.selector,
                ProgrammableLaunchInitializer.Phase.Uninitialized,
                ProgrammableLaunchInitializer.Phase.Active
            )
        );
        initializer.unlockCallback(bytes(""));
    }

    function testPermanentOnePercentFeeRunsThroughRealPoolManagerAtBoundary() public {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = _parameters();
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        uint256 value = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        vm.deal(address(this), value + 1 ether);
        graphFactory.launch{ value: value }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        NativeBuyHarness buyer = new NativeBuyHarness(manager);
        PoolKey memory key = _poolKey();
        vm.warp(1_000_030);
        vm.recordLogs();
        uint128 output =
            buyer.buy{ value: 0.01 ether }(key, 0.01 ether, 1, TickMath.getSqrtPriceAtTick(-2000), address(this));

        assertGt(output, 0);
        assertEq(_lastPoolManagerSwapFee(vm.getRecordedLogs()), 10_000);
        assertEq(hook.firstSwapTimestamp(), 1_000_000);
        assertEq(hook.feeEndTimestamp(), 1_000_030);
    }

    function testConstructorRejectsWrongFactoryCaller() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammableLaunchInitializer.UnauthorizedDeploymentFactory.selector,
                address(this),
                address(graphFactory)
            )
        );
        new ProgrammableLaunchInitializer(
            address(graphFactory), address(graphFactory).codehash, POOL_MANAGER.codehash, POSITION_MANAGER.codehash
        );
    }

    function testConstructorRejectsWrongChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ProgrammableLaunchInitializer.WrongChain.selector, 1));
        graphFactory.deployInitializer(POOL_MANAGER.codehash, POSITION_MANAGER.codehash);
    }

    function _parameters() internal view returns (ProgrammableLaunchInitializer.LaunchParameters memory) {
        return ProgrammableLaunchInitializer.LaunchParameters({
            initialSqrtPriceX96: INITIAL_PRICE,
            initialBuySqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-1000),
            lpNativeBudget: 100 ether,
            initialBuyNativeAmount: 0.1 ether,
            minimumInitialBuyTokenOut: 0.01 ether,
            deadline: block.timestamp + 10 minutes
        });
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _lastPoolManagerSwapFee(Vm.Log[] memory entries) internal pure returns (uint24 fee) {
        bool found;
        for (uint256 i = entries.length; i > 0; --i) {
            Vm.Log memory entry = entries[i - 1];
            if (entry.emitter == POOL_MANAGER && entry.topics.length != 0 && entry.topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
                break;
            }
        }
        assertTrue(found, "PoolManager Swap event missing");
    }
}

contract GraphFactoryHarness {
    function deployInitializer(bytes32 poolManagerCodeHash, bytes32 positionManagerCodeHash)
        external
        returns (ProgrammableLaunchInitializer)
    {
        return new ProgrammableLaunchInitializer(
            address(this), address(this).codehash, poolManagerCodeHash, positionManagerCodeHash
        );
    }

    function launch(
        ProgrammableLaunchInitializer initializer,
        address token,
        address hook,
        bytes32 tokenCodeHash,
        bytes32 hookCodeHash,
        ProgrammableLaunchInitializer.LaunchParameters calldata parameters
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint128 boughtTokens) {
        return initializer.initialize{ value: msg.value }(token, hook, tokenCodeHash, hookCodeHash, parameters);
    }
}

contract PositionManagerHarness is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint256 public nextTokenId;
    uint256 public nextTokenIdIncrement;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint128) public positionLiquidity;

    struct MintPositionPayload {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        address owner;
        bytes hookData;
    }

    struct SettlementPayload {
        Currency currency;
        uint256 amount;
        bool payerIsUser;
    }

    function configure() external {
        require(nextTokenId == 0);
        nextTokenId = 1;
        nextTokenIdIncrement = 1;
    }

    function setNextTokenIdIncrement(uint256 increment) external {
        nextTokenIdIncrement = increment;
    }

    function poolManager() external pure returns (IPoolManager) {
        return IPoolManager(POOL_MANAGER);
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return positionLiquidity[tokenId];
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        require(block.timestamp <= deadline, "deadline");
        IPoolManager(POOL_MANAGER).unlock(unlockData);
    }

    function unlockCallback(bytes calldata unlockData) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "manager");
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(keccak256(actions) == keccak256(hex"020b0b"), "actions");
        require(params.length == 3, "params");

        MintPositionPayload memory mint = abi.decode(params[0], (MintPositionPayload));
        SettlementPayload memory settle0 = abi.decode(params[1], (SettlementPayload));
        SettlementPayload memory settle1 = abi.decode(params[2], (SettlementPayload));
        require(
            Currency.unwrap(settle0.currency) == Currency.unwrap(mint.key.currency0) && settle0.amount == 0
                && !settle0.payerIsUser,
            "settle0"
        );
        require(
            Currency.unwrap(settle1.currency) == Currency.unwrap(mint.key.currency1) && settle1.amount == 0
                && !settle1.payerIsUser,
            "settle1"
        );

        uint256 tokenId = nextTokenId;
        nextTokenId += nextTokenIdIncrement;
        (BalanceDelta delta,) = IPoolManager(POOL_MANAGER)
            .modifyLiquidity(
                mint.key,
                ModifyLiquidityParams({
                    tickLower: mint.tickLower,
                    tickUpper: mint.tickUpper,
                    liquidityDelta: int256(mint.liquidity),
                    salt: bytes32(tokenId)
                }),
                mint.hookData
            );

        uint128 nativeDebt = uint128(-delta.amount0());
        uint128 tokenDebt = uint128(-delta.amount1());
        require(nativeDebt <= mint.amount0Max && tokenDebt <= mint.amount1Max, "max");
        require(address(this).balance >= nativeDebt, "native");
        IPoolManager(POOL_MANAGER).settle{ value: nativeDebt }();
        IPoolManager(POOL_MANAGER).sync(mint.key.currency1);
        IERC20(Currency.unwrap(mint.key.currency1)).safeTransfer(POOL_MANAGER, tokenDebt);
        IPoolManager(POOL_MANAGER).settle();

        ownerOf[tokenId] = mint.owner;
        positionLiquidity[tokenId] = uint128(mint.liquidity);
        return bytes("");
    }
}

contract NativeBuyHarness is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function buy(PoolKey memory key, uint128 amount, uint128 minimumOut, uint160 priceLimit, address recipient)
        external
        payable
        returns (uint128 output)
    {
        require(msg.value == amount);
        bytes memory result = manager.unlock(abi.encode(key, amount, minimumOut, priceLimit, recipient));
        return abi.decode(result, (uint128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, uint128 amount, uint128 minimumOut, uint160 priceLimit, address recipient) =
            abi.decode(data, (PoolKey, uint128, uint128, uint160, address));
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(uint256(amount)), sqrtPriceLimitX96: priceLimit }),
            bytes("")
        );
        uint128 spent = uint128(-delta.amount0());
        uint128 output = uint128(delta.amount1());
        require(spent == amount && output >= minimumOut);
        manager.settle{ value: spent }();
        manager.take(key.currency1, recipient, output);
        return abi.encode(output);
    }
}
