// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ProgrammableLaunchFeeHook } from "../src/ProgrammableLaunchFeeHook.sol";

contract ProgrammableLaunchFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint160 internal constant EXPECTED_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant HOOK_FLAG_MASK = (1 << 14) - 1;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 1 << 96;

    ProgrammableLaunchFeeHook internal hook;
    PoolKey internal key;
    address internal token;
    address internal initializer;

    function setUp() public {
        vm.chainId(4663);
        token = makeAddr("programmableToken");
        initializer = makeAddr("authorizedAtomicLauncher");

        bytes memory constructorArgs = abi.encode(token, initializer, TICK_SPACING, INITIAL_SQRT_PRICE_X96);
        (address expectedAddress, bytes32 salt) = HookMiner.find(
            address(this), EXPECTED_FLAGS, type(ProgrammableLaunchFeeHook).creationCode, constructorArgs
        );
        hook = new ProgrammableLaunchFeeHook{ salt: salt }(token, initializer, TICK_SPACING, INITIAL_SQRT_PRICE_X96);
        assertEq(address(hook), expectedAddress);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function testHookAddressAndPermissionsEnableOnlyInitializationGuardAndFeeOverride() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertEq(uint160(address(hook)) & HOOK_FLAG_MASK, EXPECTED_FLAGS);
        assertTrue(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertFalse(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    function testConstructorBindsRobinhoodAndCanonicalPool() public view {
        assertEq(address(hook.poolManager()), POOL_MANAGER);
        assertEq(hook.TOKEN(), token);
        assertEq(hook.AUTHORIZED_INITIALIZER(), initializer);
        assertEq(hook.TICK_SPACING(), TICK_SPACING);
        assertEq(hook.INITIAL_SQRT_PRICE_X96(), INITIAL_SQRT_PRICE_X96);
        assertEq(hook.canonicalPoolId(), PoolId.unwrap(key.toId()));
    }

    function testAuthorizedInitializerCanInitializeOnlyExactPoolAndPrice() public {
        vm.prank(POOL_MANAGER);
        bytes4 response = hook.beforeInitialize(initializer, key, INITIAL_SQRT_PRICE_X96);

        assertEq(response, IHooks.beforeInitialize.selector);
        assertTrue(hook.poolInitialized());
        assertEq(hook.firstSwapTimestamp(), 0);
        assertEq(hook.feeEndTimestamp(), 0);
    }

    function testInitializationRejectsUnauthorizedSender() public {
        vm.prank(POOL_MANAGER);
        vm.expectRevert(ProgrammableLaunchFeeHook.UnauthorizedInitializer.selector);
        hook.beforeInitialize(makeAddr("attacker"), key, INITIAL_SQRT_PRICE_X96);
    }

    function testInitializationRejectsWrongPrice() public {
        vm.prank(POOL_MANAGER);
        vm.expectRevert(ProgrammableLaunchFeeHook.InvalidInitialPrice.selector);
        hook.beforeInitialize(initializer, key, INITIAL_SQRT_PRICE_X96 + 1);
    }

    function testInitializationRejectsAStaticFeePool() public {
        key.fee = 10_000;
        vm.prank(POOL_MANAGER);
        vm.expectRevert(ProgrammableLaunchFeeHook.InvalidPoolKey.selector);
        hook.beforeInitialize(initializer, key, INITIAL_SQRT_PRICE_X96);
    }

    function testInitializationRejectsAnyOtherToken() public {
        key.currency1 = Currency.wrap(makeAddr("otherToken"));
        vm.prank(POOL_MANAGER);
        vm.expectRevert(ProgrammableLaunchFeeHook.InvalidPoolKey.selector);
        hook.beforeInitialize(initializer, key, INITIAL_SQRT_PRICE_X96);
    }

    function testInitializationCanOnlyHappenOnce() public {
        _initialize();
        vm.prank(POOL_MANAGER);
        vm.expectRevert(ProgrammableLaunchFeeHook.AlreadyInitialized.selector);
        hook.beforeInitialize(initializer, key, INITIAL_SQRT_PRICE_X96);
    }

    function testDirectCallbackFromAnyAddressOtherThanPoolManagerReverts() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(initializer, key, INITIAL_SQRT_PRICE_X96);
    }

    function testSwapBeforeInitializationRevertsAndCannotStartTimer() public {
        vm.prank(POOL_MANAGER);
        vm.expectRevert(ProgrammableLaunchFeeHook.PoolNotInitialized.selector);
        hook.beforeSwap(initializer, key, _params(true, -1 ether), bytes(""));
        assertEq(hook.feeEndTimestamp(), 0);
    }

    function testOnlyAtomicInitializerCanStartLaunchFeeWindow() public {
        _initialize();
        vm.warp(1_000_000);
        address attackerRouter = makeAddr("attackerRouter");

        vm.prank(POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableLaunchFeeHook.UnauthorizedFirstSwap.selector, attackerRouter)
        );
        hook.beforeSwap(attackerRouter, key, _params(true, -1 ether), bytes(""));

        assertEq(hook.firstSwapTimestamp(), 0);
        assertEq(hook.feeEndTimestamp(), 0);
    }

    function testEverySenderIsPermissionlessAfterAtomicInitializerStartsWindow() public {
        _startAt(1_000_000);

        vm.prank(POOL_MANAGER);
        (, BeforeSwapDelta delta, uint24 feeWithFlag) =
            hook.beforeSwap(makeAddr("universalRouter"), key, _params(false, -1 ether), bytes(""));

        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(feeWithFlag, uint24(300_000) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function testFirstSwapStartsThirtySecondWindowAndPaysThirtyPercent() public {
        _initialize();
        vm.warp(1_000_000);

        _assertSwapFee(_params(true, -1 ether), bytes(""), 300_000);

        assertEq(hook.firstSwapTimestamp(), 1_000_000);
        assertEq(hook.feeEndTimestamp(), 1_000_030);
    }

    function testLaterSwapsCannotResetLaunchWindow() public {
        _startAt(1_000_000);
        vm.warp(1_000_010);
        _assertSwapFee(_params(false, -1 ether), bytes(""), 300_000);

        assertEq(hook.firstSwapTimestamp(), 1_000_000);
        assertEq(hook.feeEndTimestamp(), 1_000_030);
    }

    function testFeeRemainsThirtyPercentAtLastSecondOfLaunchWindow() public {
        _startAt(1_000_000);
        vm.warp(1_000_029);
        _assertSwapFee(_params(false, 1 ether), hex"1234", 300_000);
    }

    function testFeeSwitchesDirectlyToOnePercentAtExactBoundary() public {
        _startAt(1_000_000);
        vm.warp(1_000_030);
        _assertSwapFee(_params(true, 1 ether), bytes("arbitrary hook data"), 10_000);
    }

    function testFeeStaysOnePercentForeverAfterBoundary() public {
        _startAt(1_000_000);
        vm.warp(10_000_000);
        _assertSwapFee(_params(false, -1 ether), hex"00", 10_000);
    }

    function testAllSwapDirectionsAndExactnessModesUseTheSameCurrentFee() public {
        _startAt(1_000_000);
        vm.warp(1_000_005);

        _assertSwapFee(_params(true, -1 ether), bytes(""), 300_000);
        _assertSwapFee(_params(false, -1 ether), bytes(""), 300_000);
        _assertSwapFee(_params(true, 1 ether), bytes(""), 300_000);
        _assertSwapFee(_params(false, 1 ether), bytes(""), 300_000);
    }

    function testMalformedHookDataIsNeverDecoded() public {
        _startAt(1_000_000);
        vm.warp(1_000_030);
        _assertSwapFee(_params(true, -1 ether), hex"ff000102ff", 10_000);
    }

    function testSwapRejectsAnyPoolOtherThanCanonicalBeforeStateChanges() public {
        _initialize();
        PoolKey memory otherKey = key;
        otherKey.tickSpacing = 10;

        vm.prank(POOL_MANAGER);
        vm.expectRevert(ProgrammableLaunchFeeHook.UnexpectedPool.selector);
        hook.beforeSwap(address(this), otherKey, _params(true, -1 ether), bytes(""));
        assertEq(hook.feeEndTimestamp(), 0);
    }

    function testCurrentFeeViewMatchesBoundary() public {
        _startAt(1_000_000);
        vm.warp(1_000_029);
        assertEq(hook.currentLPFeePips(), 300_000);
        vm.warp(1_000_030);
        assertEq(hook.currentLPFeePips(), 10_000);
    }

    function testFuzzFeeIsAlwaysOneOfTheTwoDeclaredValues(uint32 elapsed) public {
        _startAt(1_000_000);
        vm.warp(1_000_000 + uint256(elapsed));
        uint24 fee = hook.currentLPFeePips();
        assertTrue(fee == 300_000 || fee == 10_000);
        assertEq(fee, elapsed < 30 ? 300_000 : 10_000);
    }

    function _initialize() internal {
        vm.prank(POOL_MANAGER);
        hook.beforeInitialize(initializer, key, INITIAL_SQRT_PRICE_X96);
    }

    function _startAt(uint256 timestamp) internal {
        _initialize();
        vm.warp(timestamp);
        _assertSwapFee(_params(true, -1 ether), bytes(""), 300_000);
    }

    function _params(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({ zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 1 });
    }

    function _assertSwapFee(SwapParams memory params, bytes memory hookData, uint24 expectedFee) internal {
        vm.prank(POOL_MANAGER);
        (bytes4 response, BeforeSwapDelta delta, uint24 feeWithFlag) =
            hook.beforeSwap(initializer, key, params, hookData);

        assertEq(response, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(feeWithFlag, expectedFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
