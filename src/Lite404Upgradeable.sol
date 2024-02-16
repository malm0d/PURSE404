// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @notice This contract adds 404 support to an already existing ERC20Upgradeable contract
/// Note After upgrading with this contract, addresses need to be minted ERC721 tokens based on their 
///      existing ERC20 balances. An only owner/admin function in the inheriting contract must be 
///      implemented to handle this.
///      An only owner/admin function to update the `base` value must also be implemented in the
///      inheriting contract.
///
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! IMPORTANT !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// This contract was designed with a very specific utility in mind. It should be considered
/// highly experimental and should not be used in production without thorough testing.
///
/// -------------------------------------USE AT OWN RISK-------------------------------------

/// @custom:oz-upgrades-from PurseToken
abstract contract Lite404Upgradeable is Initializable, ContextUpgradeable, ERC20Upgradeable {
    /*------------------------------------------------------------*/
    /*                           Events                           */
    /*------------------------------------------------------------*/
    event ERC721Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event ERC721Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event BaseValueUpdated(uint256 newValue);

    /*------------------------------------------------------------*/
    /*                          Constants                         */
    /*------------------------------------------------------------*/

    ///@dev Current value is a placeholder, adjust accordingly
    uint256 internal constant _MAX_TOKEN_ID = 1_000_000;

    /*------------------------------------------------------------*/
    /*                           Storage                          */
    /*------------------------------------------------------------*/    

    ///@dev Current mint counter, which is also highest minted token id.
    //Also regarded as the total supply of minted NFTs
    uint256 internal _mintedNFTSupply;

    ///@dev Approvals in ERC721
    mapping(uint256 => address) public getApproved;

    ///@dev Approval for all ERC721
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @dev Array of owned ids in ERC721
    mapping(address => uint256[]) internal _owned;

    /// @dev Packed representation of ownerOf and owned indices
    struct OwnedData {
        address ownerOf;
        uint96 ownedIndex;
    }
    mapping(uint256 => OwnedData) internal _ownedData;

    ///@dev A function to allow only the owner/administrator to update this value is required
    ///     in the inheriting contract.
    uint256 public base;

    /*------------------------------------------------------------*/
    /*                        Custom Errors                       */
    /*------------------------------------------------------------*/

    error TokenDoesNotExist();
    error AlreadyExists();
    error InvalidId();
    error InvalidRecipient();
    error InvalidSender();
    error Unauthorized();

    /*------------------------------------------------------------*/
    /*                         Initializer                        */
    /*------------------------------------------------------------*/

    function __Lite404Upgradeable_init() internal onlyInitializing {}

    /*------------------------------------------------------------*/
    /*                        404 Operations                      */
    /*------------------------------------------------------------*/

    function tokenURI(uint256 id) public view virtual returns (string memory);

    ///@notice Function for 404 approvals.
    ///@dev The function handles approving an ERC721 if `_value` is less than 
    ///     or equal to `_mintedNFTSupply`. Else it handles like
    ///     an ERC20 approval.
    ///Note For ERC721 approvals `_spender` must be allowed to be 0x00 so that
    ///     the approval can be revoked. Overrides ERC20's `approve`
    function approve(address _spender, uint256 _value) public virtual override returns (bool) {
        if (_value <= _mintedNFTSupply && _value > 0) {
            //Handle like an ERC721 approval
            address nftOwner = _getOwnerOf(_value);
            if (msg.sender != nftOwner && !isApprovedForAll[nftOwner][msg.sender]) {
                revert Unauthorized();
            }

            getApproved[_value] = _spender;
            emit ERC721Approval(nftOwner, _spender, _value);
            return true;
        } else {
            //Handle like an ERC20 approval
            return super.approve(_spender, _value);
        }
    }

    ///@notice Function for 404 transferFrom
    ///@dev The function handles transferring an ERC721 if `_amountOrId` is less than
    ///     or equal to `_mintedNFTSupply`. Else it handles like an ERC20 transferFrom.
    ///Note Overrides ERC20's `transferFrom`.
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) public virtual override returns (bool) {
        //see 404 transferFrom, account for isApprovedForAll
    }

    ///@notice Function for ERC20-like transfers
    ///@dev The function handles transferring ERC20 tokens. Treats small amounts that
    ///     are valid ERC721 ids as ERC20s.
    ///Note Overrides ERC20's `transfer`.
    function transfer(address _to, uint256 _value) public virtual override returns (bool) {
        if (_to == address(0)) {
            revert InvalidRecipient();
        }
        _update(msg.sender, _to, _value);
        return true;
    }

    ///@dev Override ERC20's `_update` to handle 404 transfers - transferring ERC20 with ERC721
    ///Note Alters ERC20's: _mint, _burn, transfer, transferFrom functions
    function _update(address _from, address _to, uint256 _value) internal virtual override {
        //Cache balances at start
        uint256 senderBalanceBefore = balanceOf(_from);
        uint256 recipientBalanceBefore = balanceOf(_to);

        //Determine number of NFTs to transfer
        uint256 nftsToTransfer = _value / base;

        if (_from == address(0)) {
            //Handle ERC20 _mint case.
            //Handle whole token transfers: NFTs to transfer solely by `_value` alone.
            for (uint256 i = 0; i < nftsToTransfer;) {
                _mintERC721(_to);
                unchecked { i++; }
            }
            //Since its a mint, only account for recipient's fractional changes
            _accountForRecipientFractionals(_to, recipientBalanceBefore, _value);

        } else if (_to == address(0)) {
            //Handle ERC20 _burn case
            //Handle whole token transfers: NFTs to transfer solely by `_value` alone.
            for (uint256 i = 0; i < nftsToTransfer;) {
                _burnERC721(_from);
                unchecked { i++; }
            }
            //Since its a burn, only account for sender's fractional changes
            _accountForSenderFractionals(_from, senderBalanceBefore, _value);

        } else {
            //Handle ERC20 regular transfers
            //Handle whole token transfers: NFTs to transfer solely by `_value` alone.
            for (uint256 i = 0; i < nftsToTransfer;) {
                _transferERC721(_from, _to, _value);
                unchecked { i++; }
            }
            //Account for sender's and recipient's fractional changes.
            _accountForSenderFractionals(_from, senderBalanceBefore, _value);
            _accountForRecipientFractionals(_to, recipientBalanceBefore, _value);
        }

        //call ERC20's `_update` to account for ERC20 transfers
        super._update(_from, _to, _value);
    }

    ///@dev Accounts for sender's fractional changes.
    ///    Checks if the transfer causes the sender to lose a whole token that was represented by
    ///    an ERC721 due to a fractional amount being sent.
    function _accountForSenderFractionals(address _sender, uint256 _balSenderBefore, uint256 _value) internal virtual {
        uint256 fractionalAmount = _value % base;
        if(((_balSenderBefore - fractionalAmount) / base) < (_balSenderBefore / base)) {
            _burnERC721(_sender);
        }
        return;
    }

    ///@dev Accounts for recipient's fractional changes.
    ///    Checks if the transfer causes the recipient to earn a whole token that is represented by
    ///    an ERC721 due to a fractional amount being received.
    function _accountForRecipientFractionals(address _recipient, uint256 _balRecipientBefore, uint256 _value) internal virtual {
        uint256 fractionalAmount = _value % base;
        if(((_balRecipientBefore + fractionalAmount) / base) > (_balRecipientBefore / base)) {
            _mintERC721(_recipient);
        }
        return;
    }

    /*------------------------------------------------------------*/
    /*                       ERC721 Operations                    */
    /*------------------------------------------------------------*/

    ///@notice Function for ERC721 setApprovalForAll
    function setApprovalForAll(address _operator, bool _approved) public virtual {
        require(_operator != address(0), "404: Invalid operator address");
        isApprovedForAll[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    ///@notice Function for ERC721 safeTransferFrom with contract support
    function safeTransferFrom(address _from, address _to, uint256 _id) public virtual {
        safeTransferFrom(_from, _to, _id, "");
    }

    ///@notice Function for ERC721 safeTransferFrom with contract support and callback data
    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _id,
        bytes memory _data
    ) public virtual {
        if (_id > _mintedNFTSupply || _id == 0) {
            revert InvalidId();
        }

        transferFrom(_from, _to, _id);

        if (_isContract(_to)) {
            _checkOnERC721Received(_from, _to, _id, _data);
        }
    }

    ///@notice Function for ERC721 _checkOnERC721Received
    ///@dev Performs a call to {IERC721Receiver-onERC721Received} on `to`.
    ///     Reverts if the target is a contract and does not support the function correctly.
    ///
    ///Note Use assembly to save gas. To be used together with `isContract`.
    function _checkOnERC721Received(address from, address to, uint256 id, bytes memory data) private {
        /// @solidity memory-safe-assembly
        assembly {
            // Prepare the calldata.
            let m := mload(0x40)                            // @ 0x80
            let onERC721ReceivedSelector := 0x150b7a02
            mstore(m, onERC721ReceivedSelector)
            mstore(add(m, 0x20), caller())                  // The `operator`, which is always `msg.sender`.
            mstore(add(m, 0x40), shr(96, shl(96, from)))    // `from` as uint160
            mstore(add(m, 0x60), id)                        // token id
            mstore(add(m, 0x80), 0x80)                      // offset to `data`
            let n := mload(data)
            mstore(add(m, 0xa0), n)                         // `data` length

            if n { pop(staticcall(gas(), 4, add(data, 0x20), n, add(m, 0xc0), n)) }

            // Revert if the call reverts.
            ///@dev The selector begins @ (0x80 + 0x1c) which is 156 bytes into the calldata
            ///     add(n, 0xa4) == n + 164, accounts for the size of the calldata,
            ///     where n is the bytes word size of `data`.
            if iszero(call(gas(), to, 0, add(m, 0x1c), add(n, 0xa4), m, 0x20)) {
                if returndatasize() {
                    // Bubble up the revert if the call reverts.
                    returndatacopy(m, 0x00, returndatasize())
                    revert(m, returndatasize())
                }
            }
            // Load the returndata and compare it.
            if iszero(eq(mload(m), shl(224, onERC721ReceivedSelector))) {
                mstore(0x00, 0xd1a57ed6) // Reverts with `TransferToNonERC721ReceiverImplementer()`.
                revert(0x1c, 0x04)
            }
        }
    }

    ///@notice Function for ERC721 mint
    function _mintERC721(address _to) internal virtual returns (uint256) {
        require(_to != address(0), "404: Zero address");

        unchecked { _mintedNFTSupply++; }
        uint256 mintableId = _mintedNFTSupply;
        require(mintableId <= _MAX_TOKEN_ID, "404: Max NFT supply reached");

        if (_getOwnerOf(mintableId) != address(0)) {
            revert AlreadyExists();
        }

        _transferERC721(address(0), _to, mintableId);
        return mintableId;
    }

    ///@notice Function for ERC721 Burn
    ///@dev Burns the last token id in the owned array of `_owner`
    ///     Burning is a transfer to the zero address
    function _burnERC721(address _from) internal virtual {
        require(_from != address(0), "404: Zero address");
        uint256 _id = _owned[_from][_owned[_from].length - 1];
        _transferERC721(_from, address(0), _id);
    }

    ///@notice Pure ERC721 transfer
    ///@dev Assign token to new owner, remove from old owner.
    ///Note Transfers to and from 0x00 are allowed.
    function _transferERC721(
        address _from,
        address _to,
        uint256 _id
    ) internal virtual {
        //If transfer is not part of mint, handle record keeping from prev owner
        if (_from != address(0)) {
            //Reset approval for token id
            delete getApproved[_id];
            
            //Get the last token id in the owned array
            uint256 updatedId = _owned[_from][_owned[_from].length - 1];

            //If the `id` is not the last token id, perform swap-like update of the owned array
            if (updatedId != _id) {
                //Get the index of `_id` in the owned array
                uint96 index = _getOwnedIndex(_id);
                //Update the owned array with the last token id
                _owned[_from][index] = updatedId;
                //Update the owned index of the last token id
                _setOwnedIndex(updatedId, index);
            }

            //Pop the last token id from the owned array
            _owned[_from].pop();
        }

        //Check if transfer is part of burn
        if (_to != address(0)) {
            //If not burning, update the owner of `_id` to the new owner: `_to`
            _setOwnerOf(_id, _to);
            //Update the owned array of the new owner
            _owned[_to].push(_id);
            //Update the owned index of `_id` to the last index in `_to`'s owned array
            _setOwnedIndex(_id, uint96(_owned[_to].length - 1));
        } else {
            //If burning, reset owner of `_id` to zero address and its owned index to 0
            _setOwnerOf(_id, address(0));
            _setOwnedIndex(_id, 0);
        }

        emit ERC721Transfer(_from, _to, _id);
    }

    ///@dev Returns the owner of token `id`
    function ownerOf(uint256 id) public view virtual returns (address) {
        address _owner = _getOwnerOf(id);
        if (id > _mintedNFTSupply || id == 0 || _owner == address(0)) {
            revert TokenDoesNotExist();
        }
        return _owner;
    }

    ///@dev Returns all owned token ids of `owner`
    function owned(address _owner) public view virtual returns (uint256[] memory) {
        return _owned[_owner];
    }

    ///@dev Returns the erc721 balance of `owner`
    function erc721BalanceOf(address _owner) public view virtual returns (uint256) {
        return _owned[_owner].length;
    }

    ///@dev Returns the total supply of minted NFTs
    function erc721TotalSupply() public view virtual returns (uint256) {
        return _mintedNFTSupply;
    }

    /*------------------------------------------------------------*/
    /*                           Utility                          */
    /*------------------------------------------------------------*/

    ///@dev Check if "addr" has bytecode or not
    function _isContract(address addr) private view returns (bool res) {
        /// @solidity memory-safe-assembly
        assembly {
            res := extcodesize(addr)
        }
    }

    function _getOwnerOf(uint256 id) internal view virtual returns (address) {
        return _ownedData[id].ownerOf;
    }

    function _setOwnerOf(uint256 id, address owner) internal virtual {
        _ownedData[id].ownerOf = owner;
    }

    function _getOwnedIndex(uint256 id) internal view virtual returns (uint96) {
        return _ownedData[id].ownedIndex;
    }

    function _setOwnedIndex(uint256 id, uint96 index) internal virtual {
        _ownedData[id].ownedIndex = index;
    }
}   
