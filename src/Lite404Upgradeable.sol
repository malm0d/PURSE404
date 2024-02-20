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
/// HIGHLY experimental and should not be used in production without thorough testing.
///
/// -------------------------------------USE AT OWN RISK-------------------------------------

/// @custom:oz-upgrades-from PurseToken
abstract contract Lite404Upgradeable is Initializable, ContextUpgradeable, ERC20Upgradeable {

    /*------------------------------------------------------------------------*/
    /*                                 Events                                 */
    /*------------------------------------------------------------------------*/

    event ERC721Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event ERC721Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event BaseValueUpdated(uint256 newValue);

    /*------------------------------------------------------------------------*/
    /*                                Constants                               */
    /*------------------------------------------------------------------------*/

    ///@dev Current value is a placeholder, adjust accordingly
    uint256 internal constant _MAX_TOKEN_ID = 1_000_000;

    ///@dev Token id prefix. This is the same as: 2 ** 255.
    ///Note Every token id will be represented as: ID_ENCODING_PREFIX + id
    ///     This allows for a simple way to differentiate between ERC20 and ERC721 tokens,
    ///     and allows 2 ** 255 - 1 token ids to be minted.
    uint256 public constant ID_ENCODING_PREFIX = 1 << 255;

    /*------------------------------------------------------------------------*/
    /*                                 Storage                                */
    /*------------------------------------------------------------------------*/    

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

    /*------------------------------------------------------------------------*/
    /*                              Custom Errors                             */
    /*------------------------------------------------------------------------*/

    error NotFound();
    error AlreadyExists();
    error InvalidId();
    error InvalidRecipient();
    error InvalidSender();
    error Unauthorized();
    error ERC721MintLimitReached();
    error ERC721InsufficientBalance();

    /*------------------------------------------------------------------------*/
    /*                               Initializer                              */
    /*------------------------------------------------------------------------*/

    function __Lite404Upgradeable_init() internal onlyInitializing {}

    /*------------------------------------------------------------------------*/
    /*                           Public 404 Operations                        */
    /*------------------------------------------------------------------------*/

    function tokenURI(uint256 id) public view virtual returns (string memory);

    ///@notice Function for 404 approvals.
    ///@dev The function handles approving an ERC721 if `_valueOrId` is a valid ERC721 token id. 
    ///     Else it handles like an ERC20 approval. Overrides ERC20's `approve`.
    ///Note For ERC721 approvals `_spender` must be allowed to be 0x00 so that
    ///     the approval can be revoked.
    function approve(address _spender, uint256 _valueOrId) public virtual override returns (bool) {
        if (_isValidTokenId(_valueOrId)) {
            //Handle like an ERC721 approval
            address nftOwner = _getOwnerOf(_valueOrId);
            if (msg.sender != nftOwner && !isApprovedForAll[nftOwner][msg.sender]) {
                revert Unauthorized();
            }

            getApproved[_valueOrId] = _spender;
            emit ERC721Approval(nftOwner, _spender, _valueOrId);
            return true;
        } else {
            //Handle like an ERC20 approval
            return super.approve(_spender, _valueOrId);
        }
    }

    ///@notice Function for ERC20 transfers, with 404 context.
    ///@dev The function handles transferring ERC20 tokens. Treats large amounts that are valid
    ///     ERC721 token ids as ERC20s. Overrides ERC20's `transfer`.
    ///Note Direct NFT transfers should be handled with `transferFromERC721`.
    function transfer(address _to, uint256 _value) public virtual override returns (bool) {
        if (_to == address(0)) {
            revert InvalidRecipient();
        }
        _transferERC20WithERC721(msg.sender, _to, _value);
        return true;
    }

    ///@notice Function for mixed transfers from an operator that may be different than `_from`.
    ///@dev The function assumes that the transfer is for an ERC721 token id if `_valueOrId` is a valid id
    ///     as per `_isValidTokenId`. If so, it handles the transfer like an ERC721 `transferFrom`.
    ///     Else handles like an ERC20 `transferFrom`. Overrides ERC20's `transferFrom`.
    function transferFrom(
        address _from,
        address _to,
        uint256 _valueOrId
    ) public virtual override returns (bool) {
        if (_isValidTokenId(_valueOrId)) {
            transferFromERC721(_from, _to, _valueOrId);
        } else {
            _spendAllowance(_from, msg.sender, _valueOrId);
            _transferERC20WithERC721(_from, _to, _valueOrId);
        }
        return true;
    }

    ///@notice Function for ERC20 minting, with 404 context.
    ///@dev Allows minting of ERC20s with 404 context. Cannot mint to zero address.
    ///     Emits ERC20 `Transfer` and `ERC721Transfer` events.
    function mint(address _to, uint256 _value) public virtual returns (bool) {
        //Cache before-balances of recipient
        uint256 balBefore = balanceOf(_to);

        //Mint ERC20 tokens
        super._mint(_to, _value);

        //Determine number of NFTs to mint along with amount of ERC20 tokens
        uint256 nftsToTransfer = _value / base;

        //Handle whole token transfers: NFTs to mint solely by `_value` alone.
        for (uint256 i = 0; i < nftsToTransfer;) {
            _mintERC721(_to);
            unchecked { i++; }
        }

        //Account for recipient's fractional changes.
        _accountForRecipientFractionals(_to, balBefore, nftsToTransfer);
        return true;
    }

    ///@notice Function for ERC20 burning, with 404 context.
    ///@dev Allows burning of ERC20s with 404 context. Cannot burn from zero address.
    ///     Emits ERC20 `Transfer` and `ERC721Transfer` events.
    function burn(address _from, uint256 _value) public virtual returns (bool) {
        //Cache before-balances of sender
        uint256 balBefore = balanceOf(_from);

        //Burn ERC20 tokens
        super._burn(_from, _value);

        //Determine number of NFTs to burn along with amount of ERC20 tokens
        uint256 nftsToTransfer = _value / base;

        //Handle whole token transfers: NFTs to burn solely by `_value` alone.
        for (uint256 i = 0; i < nftsToTransfer;) {
            _burnERC721(_from);
            unchecked { i++; }
        }

        //Account for sender's fractional changes.
        _accountForSenderFractionals(_from, balBefore, nftsToTransfer);
        return true;
    }

    /*------------------------------------------------------------------------*/
    /*                          Internal 404 Operations                       */
    /*------------------------------------------------------------------------*/

    ///@dev Internal function to handle ERC20 transfers with ERC721.
    ///     Emits ERC20 `Transfer` and `ERC721Transfer` events.
    ///Note We should not override ERC20's `_update` as it will affect all ERC20 operations.
    ///     This must and can only be used together with ERC20's `transfer`, `transferFrom`.
    ///     CANNOT be used with ERC20's `_mint` and `_burn` because `_transferERC20` does not allow
    ///     minting tokens from zero address and burning tokens to zero address.
    function _transferERC20WithERC721(address _from, address _to, uint256 _value) internal virtual {
        //Cache before-balances of sender and recipient
        uint256 senderBalanceBefore = balanceOf(_from);
        uint256 recipientBalanceBefore = balanceOf(_to);

        _transferERC20(_from, _to, _value);

        //Determine number of NFTs to transfer
        uint256 nftsToTransfer = _value / base;

        //Check if `_from` has enough NFTs to transfer
        if (balanceOfERC721(_from) < nftsToTransfer) {
            revert ERC721InsufficientBalance();
        }

        //Handle whole token transfers: NFTs to transfer solely by `_value` alone.
        for (uint256 i = 0; i < nftsToTransfer;) {
            //Get sender's ERC721 and transfer them to recipient
            uint256 senderLastTokenId = _owned[_from][_owned[_from].length - 1];
            _transferERC721(_from, _to, senderLastTokenId);
            unchecked { i++; }
        }

        //Account for sender's and recipient's fractional changes.
        _accountForSenderFractionals(_from, senderBalanceBefore, nftsToTransfer);
        _accountForRecipientFractionals(_to, recipientBalanceBefore, nftsToTransfer);
    }

    ///@dev Accounts for sender's fractional changes.
    ///     Checks if the transfer causes the sender to lose a whole token that was represented by
    ///     an ERC721 due to a fractional amount being sent.
    ///Note Accounts for self-send, no ERC721 burned in this case.
    function _accountForSenderFractionals(address _sender, uint256 _balSenderBefore, uint256 _nftsToTransfer) internal virtual {
        if(_balSenderBefore / base - balanceOf(_sender) / base > _nftsToTransfer) {
            _burnERC721(_sender);
        }
        return;
    }

    ///@dev Accounts for recipient's fractional changes.
    ///     Checks if the transfer causes the recipient to earn a whole token that is represented by
    ///     an ERC721 due to a fractional amount being received.
    ///Note Accounts for self-receive, no ERC721 minted in this case.
    function _accountForRecipientFractionals(address _recipient, uint256 _balRecipientBefore, uint256 _nftsToTransfer) internal virtual {
        if(balanceOf(_recipient) / base - _balRecipientBefore / base > _nftsToTransfer) {
            _mintERC721(_recipient);
        }
        return;
    }

    ///@notice Pure ERC20 transfer.
    ///@dev Uses ERC20's `_transfer` to handle ERC20 transfers.
    ///     Prevents minting tokens from zero address.
    //      Prevents burning of tokens to zero address.
    function _transferERC20(address _from, address _to, uint256 _value) internal {
        super._transfer(_from, _to, _value);
    }

    /*------------------------------------------------------------------------*/
    /*                           ERC721 View Operations                       */
    /*------------------------------------------------------------------------*/

    ///@dev Returns the owner of token `id`.
    function ownerOf(uint256 id) public view virtual returns (address) {
        address _owner = _getOwnerOf(id);
        if (!_isValidTokenId(id)) {
            revert InvalidId();
        }
        if (_owner == address(0)) {
            revert NotFound();
        }
        return _owner;
    }

    ///@dev Returns all owned token ids of `owner`.
    function owned(address _owner) public view virtual returns (uint256[] memory) {
        return _owned[_owner];
    }

    ///@dev Returns the erc721 balance of `owner`.
    function balanceOfERC721(address _owner) public view virtual returns (uint256) {
        return _owned[_owner].length;
    }

    ///@dev Returns the total supply of minted NFTs.
    function totalSupplyERC721() public view virtual returns (uint256) {
        return _mintedNFTSupply;
    }

    /*------------------------------------------------------------------------*/
    /*                          ERC721 Public Operations                      */
    /*------------------------------------------------------------------------*/

    ///@notice Function for ERC721 setApprovalForAll.
    function setApprovalForAll(address _operator, bool _approved) public virtual {
        require(_operator != address(0), "404: Invalid operator address");
        isApprovedForAll[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    ///@notice Function for ERC721 transfers from.
    ///@dev Transfers only 1 * base amount of ERC20 tokens and 1 ERC721 token.
    ///     Does not allow zero address for `_from` and `_to`.
    ///     Emits ERC20 `Transfer` and `ERC721Transfer` events.
    ///Note Recommended use for ERC721 related transfers. Does not include callback check.
    function transferFromERC721(address _from, address _to, uint256 _id) public virtual {
        //Check `_from` is the owner of `_id`
        if  (_from != _getOwnerOf(_id)) {
            revert Unauthorized();
        }

        if (_from == address(0)) {
            revert InvalidSender();
        }

        if (_to == address(0)) {
            revert InvalidRecipient();
        }

        //Check that the operator is either sender or approved for the transfer
        //Reverts if the operator is not the sender, not approved for all, and not approved for the transfer
        if (
            msg.sender != _from
            && !isApprovedForAll[_from][msg.sender]
            && msg.sender != getApproved[_id]
        ) {
            revert Unauthorized();
        }

        _transferERC20(_from, _to, base);
        _transferERC721(_from, _to, _id);
    }

    ///@notice Function for ERC721 safeTransferFrom with contract support.
    ///        Only allows safeTransferFrom of valid ERC721 token ids. Cannot be used with ERC20.
    ///Note Recommended for ERC721 transfers that require a safe callback check.
    function safeTransferFrom(address _from, address _to, uint256 _id) public virtual {
        safeTransferFrom(_from, _to, _id, "");
    }

    ///@notice Function for ERC721 safeTransferFrom with contract support and callback data.
    ///        Only allows safeTransferFrom of valid ERC721 token ids. Cannot be used with ERC20.
    ///Note Recommended for ERC721 transfers that require a safe callback check.
    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _id,
        bytes memory _data
    ) public virtual {
        if (!_isValidTokenId(_id)) {
            revert InvalidId();
        }

        transferFrom(_from, _to, _id);

        if (_isContract(_to)) {
            _checkOnERC721Received(_from, _to, _id, _data);
        }
    }

    /*------------------------------------------------------------------------*/
    /*                         ERC721 Internal Operations                     */
    /*------------------------------------------------------------------------*/

    ///@notice Function for ERC721 _checkOnERC721Received.
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

    ///@notice Function for ERC721 mint.
    function _mintERC721(address _to) internal virtual returns (uint256) {
        require(_to != address(0), "404: Zero address");

        ++_mintedNFTSupply;
        if (_mintedNFTSupply > _MAX_TOKEN_ID) {
            revert ERC721MintLimitReached();
        }

        //Option to allow larger supply of NFT to mint
        // if (_mintedNFTSupply == type(uint256).max) {
        //     revert ERC721MintLimitReached();
        // }

        uint256 mintableId =  ID_ENCODING_PREFIX + _mintedNFTSupply;

        if (_getOwnerOf(mintableId) != address(0)) {
            revert AlreadyExists();
        }

        _transferERC721(address(0), _to, mintableId);
        return mintableId;
    }

    ///@notice Function for ERC721 Burn.
    ///@dev Burns the last token id in the owned array of `_owner`.
    ///     Burning is a transfer to the zero address.
    function _burnERC721(address _from) internal virtual {
        require(_from != address(0), "404: Zero address");
        uint256 _id = _owned[_from][_owned[_from].length - 1];
        _transferERC721(_from, address(0), _id);
    }

    ///@notice Pure ERC721 transfer.
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

    /*------------------------------------------------------------------------*/
    /*                                 Utility                                */
    /*------------------------------------------------------------------------*/

    ///@dev Check if "addr" has bytecode or not.
    function _isContract(address addr) private view returns (bool res) {
        /// @solidity memory-safe-assembly
        assembly {
            res := extcodesize(addr)
        }
    }

    ///@dev For a given token id, it will be valid if it falls within the range of possible
    ///     token ids. It does not necessarily have to be minted yet.
    ///     A token id is valid if it is greater than `ID_ENCODING_PREFIX` and not equal to `type(uint256).max`.
    ///Note Do not confuse this with `ownerOf` or `_getOwnerOf` which checks for the owner of a token id.
    function _isValidTokenId(uint256 _id) internal pure returns (bool) {
        return _id > ID_ENCODING_PREFIX && _id != type(uint256).max;
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
