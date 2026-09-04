// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ProgrammableToken } from "../src/ProgrammableToken.sol";

contract ProgrammableTokenTest is Test {
    address internal constant LAUNCH_WALLET = 0x245099E77F8F0Cad9a75B1B56db8FDE7C948d5B1;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant INITIAL_LIQUIDITY_BUDGET = 50_000_000 ether;

    ProgrammableToken internal token;
    address internal liquidityInitializer;

    function setUp() public {
        vm.chainId(4663);
        liquidityInitializer = address(new InitializerStub());
        token = new ProgrammableToken(liquidityInitializer);
    }

    function testConstructorMintsExactlyOneBillionAcrossFixedLaunchAllocation() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(LAUNCH_WALLET), TOTAL_SUPPLY - INITIAL_LIQUIDITY_BUDGET);
        assertEq(token.balanceOf(liquidityInitializer), INITIAL_LIQUIDITY_BUDGET);
        assertEq(token.INITIAL_HOLDER(), LAUNCH_WALLET);
        assertEq(token.INITIAL_LIQUIDITY_HOLDER(), liquidityInitializer);
        assertEq(token.INITIAL_LIQUIDITY_BUDGET(), INITIAL_LIQUIDITY_BUDGET);
    }

    function testMetadataMatchesPublishedLaunchIntent() public view {
        assertEq(token.name(), "Programmable");
        assertEq(token.symbol(), "V4");
        assertEq(token.decimals(), 18);
    }

    function testTransferMovesTheExactAmountWithoutTaxAndPreservesSupply() public {
        address recipient = makeAddr("recipient");
        uint256 amount = 50_000_000 ether;

        vm.prank(liquidityInitializer);
        token.transfer(recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(liquidityInitializer), 0);
        assertEq(token.balanceOf(LAUNCH_WALLET), TOTAL_SUPPLY - INITIAL_LIQUIDITY_BUDGET);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function testAllowanceAndTransferFromAreStandardERC20Behavior() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        uint256 amount = 123 ether;

        vm.prank(LAUNCH_WALLET);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(LAUNCH_WALLET, recipient, amount);

        assertEq(token.allowance(LAUNCH_WALLET, spender), 0);
        assertEq(token.balanceOf(recipient), amount);
    }

    function testDeploymentOnAnyOtherChainReverts() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ProgrammableToken.WrongChain.selector, 1));
        new ProgrammableToken(liquidityInitializer);
    }

    function testDeploymentRejectsZeroLiquidityInitializer() public {
        vm.expectRevert(ProgrammableToken.ZeroLiquidityInitializer.selector);
        new ProgrammableToken(address(0));
    }

    function testDeploymentRejectsLiquidityInitializerWithoutCode() public {
        address noCode = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(ProgrammableToken.LiquidityInitializerHasNoCode.selector, noCode));
        new ProgrammableToken(noCode);
    }

    function testUnknownMintBurnPauseAndOwnerSelectorsCannotChangeState() public {
        uint256 supplyBefore = token.totalSupply();
        bytes[5] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", address(this), 1 ether),
            abi.encodeWithSignature("burn(uint256)", 1 ether),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(this), bytes(""))
        ];

        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(token).call(calls[i]);
            assertFalse(success);
        }

        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(LAUNCH_WALLET), supplyBefore - INITIAL_LIQUIDITY_BUDGET);
        assertEq(token.balanceOf(liquidityInitializer), INITIAL_LIQUIDITY_BUDGET);
    }
}

contract InitializerStub { }
