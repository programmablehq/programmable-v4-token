// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Test } from "forge-std/Test.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ProgrammableLaunchFeeHook } from "../src/ProgrammableLaunchFeeHook.sol";
import { ProgrammableLaunchInitializer } from "../src/ProgrammableLaunchInitializer.sol";
import { ProgrammableToken } from "../src/ProgrammableToken.sol";

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

interface IUniversalRouterTrustRoot {
    function poolManager() external view returns (IPoolManager);
    function V4_POSITION_MANAGER() external view returns (address);
    function SPOKE_POOL() external view returns (address);
}

/// @dev Opt-in integration test against the real Robinhood Chain contracts at a pinned block.
///      Run with:
///      ROBINHOOD_FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///        forge test --match-contract ProgrammableLaunchRobinhoodForkTest -vvv
contract ProgrammableLaunchRobinhoodForkTest is Test {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 53_817_393;
    address internal constant LAUNCH_WALLET = 0x245099E77F8F0Cad9a75B1B56db8FDE7C948d5B1;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    address internal constant PRODUCTION_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    bytes32 internal constant POOL_MANAGER_CODE_HASH =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 internal constant POSITION_MANAGER_CODE_HASH =
        0xc873e135dc9aaec88489cfbad146b4cb49d6a32e0d80326377784b7ba17670b2;
    bytes32 internal constant UNIVERSAL_ROUTER_CODE_HASH =
        0xbe8e8191bb42d843c2e948a5a55772eaab864ce01e54dcd47c9d089170b302d5;
    uint128 internal constant EXPECTED_LP_TOKEN_AMOUNT = 49_994_026_423_634_108_769_966_157;
    uint128 internal constant EXPECTED_INITIAL_BUY_TOKEN_OUT = 34_971_338_559_552_188_263_201;
    uint160 internal constant EXPECTED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;

    IPoolManager internal manager;
    IPositionManager internal positionManager;
    ForkGraphFactoryHarness internal graphFactory;
    ProgrammableLaunchInitializer internal initializer;
    ProgrammableToken internal token;
    ProgrammableLaunchFeeHook internal hook;
    uint160 internal initialSqrtPriceX96;

    function testRobinhoodPinnedForkAtomicLaunchThroughRealPositionManager() external {
        string memory rpcUrl = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        vm.createSelectFork(rpcUrl, FORK_BLOCK);

        assertEq(block.chainid, 4663, "wrong fork chain");
        // On an Arbitrum Orbit chain the BLOCKNUMBER opcode exposes the L1 block. ArbSys exposes the pinned L2 height.
        assertEq(IArbSys(address(100)).arbBlockNumber(), FORK_BLOCK, "fork L2 block drifted");
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODE_HASH, "PoolManager runtime drifted");
        assertEq(POSITION_MANAGER.codehash, POSITION_MANAGER_CODE_HASH, "PositionManager runtime drifted");
        assertEq(UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODE_HASH, "UniversalRouter runtime drifted");

        manager = IPoolManager(POOL_MANAGER);
        positionManager = IPositionManager(POSITION_MANAGER);
        assertEq(address(positionManager.poolManager()), POOL_MANAGER, "PositionManager linkage drifted");
        IUniversalRouterTrustRoot universalRouter = IUniversalRouterTrustRoot(UNIVERSAL_ROUTER);
        assertEq(address(universalRouter.poolManager()), POOL_MANAGER, "UniversalRouter PoolManager linkage drifted");
        assertEq(
            universalRouter.V4_POSITION_MANAGER(), POSITION_MANAGER, "UniversalRouter PositionManager linkage drifted"
        );
        assertEq(universalRouter.SPOKE_POOL(), PRODUCTION_SPOKE_POOL, "UniversalRouter SpokePool linkage drifted");

        _deployLaunchGraph();
        _executeLaunchAndAssert();
    }

    function _deployLaunchGraph() private {
        graphFactory = new ForkGraphFactoryHarness();
        initializer = graphFactory.deployInitializer(POOL_MANAGER_CODE_HASH, POSITION_MANAGER_CODE_HASH);
        token = new ProgrammableToken(address(initializer));

        // 131_229 is approximately 500,000 V4 per native ETH, matching a 50m V4 / 100 ETH full-range seed.
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(131_229);
        bytes memory constructorArgs = abi.encode(address(token), address(initializer), int24(60), initialSqrtPriceX96);
        (address expectedHook, bytes32 salt) = HookMiner.find(
            address(this), EXPECTED_HOOK_FLAGS, type(ProgrammableLaunchFeeHook).creationCode, constructorArgs
        );
        hook = new ProgrammableLaunchFeeHook{ salt: salt }(
            address(token), address(initializer), 60, initialSqrtPriceX96
        );
        assertEq(address(hook), expectedHook, "mined hook address mismatch");
    }

    function _executeLaunchAndAssert() private {
        ProgrammableLaunchInitializer.LaunchParameters memory parameters = ProgrammableLaunchInitializer.LaunchParameters({
            initialSqrtPriceX96: initialSqrtPriceX96,
            initialBuySqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(130_229),
            lpNativeBudget: 100 ether,
            initialBuyNativeAmount: 0.1 ether,
            minimumInitialBuyTokenOut: 34_000 ether,
            deadline: block.timestamp + 10 minutes
        });
        ProgrammableLaunchInitializer.LiquidityPlan memory plan =
            initializer.previewLiquidity(parameters.initialSqrtPriceX96, parameters.lpNativeBudget);
        assertEq(plan.nativeAmount, 100 ether, "unexpected planned native principal");
        assertEq(plan.tokenAmount, EXPECTED_LP_TOKEN_AMOUNT, "unexpected planned V4 principal");
        uint256 requiredNative = uint256(plan.nativeAmount) + uint256(parameters.initialBuyNativeAmount);
        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        vm.deal(address(this), requiredNative);

        (uint256 tokenId, uint128 liquidity, uint128 boughtTokens) = graphFactory.launch{ value: requiredNative }(
            initializer, address(token), address(hook), address(token).codehash, address(hook).codehash, parameters
        );

        _assertCompletedLaunch(tokenId, liquidity, boughtTokens, nextTokenIdBefore, plan);
    }

    function _assertCompletedLaunch(
        uint256 tokenId,
        uint128 liquidity,
        uint128 boughtTokens,
        uint256 nextTokenIdBefore,
        ProgrammableLaunchInitializer.LiquidityPlan memory plan
    ) private view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        (uint160 finalSqrtPriceX96, int24 finalTick,, uint24 storedLPFee) = manager.getSlot0(key.toId());

        assertEq(tokenId, nextTokenIdBefore, "unexpected position token id");
        assertEq(positionManager.nextTokenId(), tokenId + 1, "position was not minted exactly once");
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), LAUNCH_WALLET, "LP NFT owner mismatch");
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity, "position liquidity mismatch");
        assertEq(manager.getLiquidity(key.toId()), liquidity, "active pool liquidity mismatch");
        assertEq(initializer.lpNativeAmount(), plan.nativeAmount, "recorded native principal mismatch");
        assertEq(initializer.lpTokenAmount(), plan.tokenAmount, "recorded token principal mismatch");
        assertEq(initializer.initialBuyTokenAmount(), boughtTokens, "recorded buy output mismatch");
        assertEq(boughtTokens, EXPECTED_INITIAL_BUY_TOKEN_OUT, "unexpected initial buy output");
        assertLt(finalSqrtPriceX96, initialSqrtPriceX96, "native-to-V4 buy did not move price down");
        assertLt(finalTick, int24(131_229), "native-to-V4 buy did not move tick down");
        assertTrue(key.fee.isDynamicFee(), "pool key is not configured for dynamic fees");
        assertEq(storedLPFee, 0, "dynamic pool initial stored fee must be zero");
        assertEq(hook.firstSwapTimestamp(), uint64(block.timestamp), "first swap did not start fee window");
        assertEq(hook.feeEndTimestamp(), uint64(block.timestamp + 30), "fee window duration mismatch");
        assertEq(hook.currentLPFeePips(), 300_000, "launch fee was not active");
        assertEq(address(initializer).balance, 0, "initializer retained native ETH");
        assertEq(token.balanceOf(address(initializer)), 0, "initializer retained V4");
    }
}

contract ForkGraphFactoryHarness {
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
