//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";

interface IPurseERC404 {

  error NotFound();
  error InvalidTokenId();
  error AlreadyExists();
  error InvalidOperator();
  error Unauthorized();
  error InsufficientAllowance();
  error InvalidApproval();
  error MintLimitReached();
  error InsufficientInactiveBalance();
  error ERC721InvalidSender(address);
  error ERC721InvalidReceiver(address);
  error IncorrectEthValue();
  error FailToSendEther();

  // function name() external view returns (string memory);
  // function symbol() external view returns (string memory);
  // function decimals() external view returns (uint8);
  // function totalSupply() external view returns (uint256);
  // function balanceOf(address owner_) external view returns (uint256);
  // function allowance(
  //   address owner_,
  //   address spender_
  // ) external view returns (uint256);
  // function transfer(address to_, uint256 amount_) external returns (bool);
  // function DOMAIN_SEPARATOR() external view returns (bytes32);
  // function permit(
  //   address owner_,
  //   address spender_,
  //   uint256 value_,
  //   uint256 deadline_,
  //   uint8 v_,
  //   bytes32 r_,
  //   bytes32 s_
  // ) external;
  function ownerOf(uint256 id_) external view returns (address erc721Owner);
  function safeTransferFrom(address from_, address to_, uint256 id_) external;
  function safeTransferFrom(
    address from_,
    address to_,
    uint256 id_,
    bytes calldata data_
  ) external;
  // function transferFrom(
  //   address from_,
  //   address to_,
  //   uint256 valueOrId_
  // ) external returns (bool);
  // function approve(
  //   address spender_,
  //   uint256 valueOrId_
  // ) external returns (bool);
  function setApprovalForAll(address operator_, bool approved_) external;
  function getApproved(uint256 _tokenId) external view returns (address);
  function isApprovedForAll(
    address owner_,
    address operator_
  ) external view returns (bool);
  function tokenURI(uint256 id_) external view returns (string memory);

  function inactiveBalance(address owner_) external view returns (uint256);
  function activeBalance(address owner_) external view returns (uint256);
  function erc721TotalSupply() external view returns (uint256);
  function erc721BalanceOf(address owner_) external view returns (uint256);
  function owned(address owner_) external view returns (uint256[] memory);
  function getERC721QueueLength() external view returns (uint256);
  function getERC721TokensInQueue(
    uint256 start_,
    uint256 count_
  ) external view returns (uint256[] memory);
}