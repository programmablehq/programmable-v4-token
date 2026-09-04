// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Programmable
/// @notice Fixed-supply V4 token for Robinhood Chain. There are no privileged runtime controls.
contract ProgrammableToken is ERC20 {
    uint256 public constant DEPLOYMENT_CHAIN_ID = 4663;
    uint256 public constant FIXED_SUPPLY = 1_000_000_000 ether;
    uint256 public constant INITIAL_LIQUIDITY_BUDGET = 50_000_000 ether;
    address public constant INITIAL_HOLDER = 0x245099E77F8F0Cad9a75B1B56db8FDE7C948d5B1;
    address public immutable INITIAL_LIQUIDITY_HOLDER;

    error WrongChain(uint256 actualChainId);
    error ZeroLiquidityInitializer();
    error LiquidityInitializerHasNoCode(address initializer);

    constructor(address liquidityInitializer) ERC20("Programmable", "V4") {
        if (block.chainid != DEPLOYMENT_CHAIN_ID) revert WrongChain(block.chainid);
        if (liquidityInitializer == address(0)) revert ZeroLiquidityInitializer();
        if (liquidityInitializer.code.length == 0) revert LiquidityInitializerHasNoCode(liquidityInitializer);

        INITIAL_LIQUIDITY_HOLDER = liquidityInitializer;
        _mint(INITIAL_HOLDER, FIXED_SUPPLY - INITIAL_LIQUIDITY_BUDGET);
        _mint(liquidityInitializer, INITIAL_LIQUIDITY_BUDGET);
    }
}
