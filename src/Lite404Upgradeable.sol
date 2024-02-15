// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract ERC721Receiver {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external virtual returns (bytes4) {
        return ERC721Receiver.onERC721Received.selector;
    }
}

/// @notice This contract adds 404 support to an already existing ERC20Upgradeable contract

abstract contract Lite404Upgradeable is Initializable, ContextUpgradeable, AccessControlUpgradeable, ERC20Upgradeable {
    /*------------------------------------------------------------*/
    /*                           EVENTS                           */
    /*------------------------------------------------------------*/
    event ERC721Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event ERC721Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /*------------------------------------------------------------*/
    /*                          CONSTANTS                         */
    /*------------------------------------------------------------*/

    ///@dev Current value is a placeholder, adjust accordingly
    uint256 internal constant _MAX_TOKEN_ID = 1_000_000;

    /*------------------------------------------------------------*/
    /*                           STORAGE                          */
    /*------------------------------------------------------------*/    

    ///@dev Current mint counter, which is also highest minted token id.
    //Also regarded as the total supply of minted NFTs
    uint256 internal _mintedNFTSupply;

    ///@dev Approvals in native representation (ERC721)
    mapping(uint256 => address) public tokenApprovals;

    ///@dev Approval for all in native representation (ERC721)
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    ///@dev Token id owner in native representation (ERC721)
    mapping(uint256 => address) internal _ownerOf;

    /// @dev Array of owned ids in native representation
    mapping(address => uint256[]) internal _owned;

    /// @dev Tracks indices for the _owned mapping
    mapping(uint256 => uint256) internal _ownedIndex;

    /// @dev Addresses whitelisted from minting / burning for gas savings (pairs, routers, etc)
    mapping(address => bool) public whitelist;

    /// @dev Role for authorized functions in this contract
    bytes32 public constant NFT_ROLE = keccak256("NFT_ROLE");

    /*------------------------------------------------------------*/
    /*                        Custom Errors                       */
    /*------------------------------------------------------------*/

    error NotFound();
    error AlreadyExists();
    error InvalidRecipient();
    error InvalidSender();
    error UnsafeRecipient();

    /*------------------------------------------------------------*/
    /*                         Initializer                        */
    /*------------------------------------------------------------*/

    function __Lite404Upgradeable_init() internal onlyInitializing {}

    /*------------------------------------------------------------*/
    /*                     Authorized Operations                  */
    /*------------------------------------------------------------*/

    ///@dev Assigns `NFT_ROLE` to the given address
    function grantNFTRole(address _address) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(NFT_ROLE, _address);
    }

    ///@dev Set the whitelist status of an address
    function setWhitelist(address _address, bool _wl) public onlyRole(NFT_ROLE) {
        whitelist[_address] = _wl;
    }

    /*------------------------------------------------------------*/
    /*                       ERC721 Operations                    */
    /*------------------------------------------------------------*/

    


}   
