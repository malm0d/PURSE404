//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//Optional errors interface for convenient.
//We can just use abi.encodeWithSelector as an alternative.
interface IERC20Errors {
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidSpender(address spender);
}