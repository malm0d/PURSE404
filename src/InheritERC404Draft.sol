//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {DoubleEndedQueue} from "./lib/DoubleEndedQueue.sol";
import {ERC721Events} from "./lib/ERC721Events.sol";
import {ERC20Events} from "./lib/ERC20Events.sol";
import {IPurseERC404} from "./interfaces/IPurseERC404.sol";
import {PurseToken} from "./PurseToken.sol";


abstract contract InheritERC404Draft is PurseToken, IPurseERC404 {
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;

    /*------------------------------------------------------------------------*/
    /*                                 Storage                                */
    /*------------------------------------------------------------------------*/    

    /// @dev The queue of ERC-721 tokens stored in the contract.
    DoubleEndedQueue.Uint256Deque private _storedERC721Ids;

    /// @dev Units for ERC-721 representation
    uint256 public units;

    /// @dev Current mint counter which also represents the highest
    ///      minted id, monotonically increasing to ensure accurate ownership
    uint256 public minted;

    /// @dev Initial chain id for EIP-2612 support
    uint256 internal _INITIAL_CHAIN_ID;

    /// @dev Initial domain separator for EIP-2612 support
    bytes32 internal _INITIAL_DOMAIN_SEPARATOR;

    /// @dev Approval in ERC-721 representaion
    mapping(uint256 => address) public getApproved;

    /// @dev Approval for all in ERC-721 representation
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @dev Array of owned ids in ERC-721 representation
    mapping(address => uint256[]) internal _owned;

    /// @dev Packed representation of ownerOf and owned indices
    struct OwnedData {
        address ownerOf;
        uint96 ownedIndex;
    }
    mapping(uint256 => OwnedData) internal _ownedData;

    /// @dev Constant for token id encoding
    uint256 public constant ID_ENCODING_PREFIX = 1 << 255;

    bytes32 private constant ERC20StorageLocation = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    ///@dev A function to allow only the owner/administrator to update this value is required
    ///     in the inheriting contract.
    uint256 internal _MAX_TOKEN_ID;

    /*------------------------------------------------------------------------*/
    /*                              Custom Errors                             */
    /*------------------------------------------------------------------------*/

    error ERC721InsufficientBalance();

    /*------------------------------------------------------------------------*/
    /*                            View 404 Operations                         */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Returns the total balance of the account.
     * @dev See {IERC20-balanceOf}.
     *      Returns the sum of all active and inactive balances.
     * Note Active balances are ERC20s reserved for NFTs, and are always a whole number.
     *      Inactive balances are ERC20s that can be fractional. 
     */
    function balanceOf(address account) public view override returns (uint256) {
        return inactiveBalance(account) + activeBalance(account);
    }

    /**
     * @dev Non-NFT-converted ERC20 balance.
     */
    function inactiveBalance(address account) public view virtual returns (uint256) {
        ERC20Storage storage $ = getERC20Storage();
        return $._balances[account];
    }

    /**
     * @dev NFT-converted ERC20 balance.
     */
    function activeBalance(address account) public view virtual returns (uint256) {
        return erc721BalanceOf(account) * units;
    }

    /// @notice Function to find owner of a given ERC-721 token
    function ownerOf(
        uint256 id_
    ) public view virtual returns (address erc721Owner) {
        erc721Owner = _getOwnerOf(id_);

        if (!_isValidTokenId(id_)) {
            revert InvalidTokenId();
        }
        
        if (erc721Owner == address(0)) {
            revert NotFound();
        }
    }

    ///@dev Returns all owned token ids of `owner`.
    function owned(address owner_) public view virtual returns (uint256[] memory) {
        return _owned[owner_];
    }

    function erc721BalanceOf(address owner_) public view virtual returns (uint256) {
        return _owned[owner_].length;
    }

    function erc20BalanceOf(
        address owner_
    ) public view virtual returns (uint256) {
        // return balanceOf[owner_];
        return balanceOf(owner_);
    }

    function erc20TotalSupply() public view virtual returns (uint256) {
        // return totalSupply;
        return totalSupply();
    }

    function erc721TotalSupply() public view virtual returns (uint256) {
        return minted;
    }

    function getERC721QueueLength() public view virtual returns (uint256) {
        return _storedERC721Ids.length();
    }

    function getERC721TokensInQueue(
        uint256 start_,
        uint256 count_
    ) public view virtual returns (uint256[] memory) {
        uint256[] memory tokensInQueue = new uint256[](count_);

        for (uint256 i = start_; i < start_ + count_; ) {
            tokensInQueue[i - start_] = _storedERC721Ids.at(i);

            unchecked {
                ++i;
            }
        }

        return tokensInQueue;
    }

    function tokenURI(uint256 id) public view virtual returns (string memory) {}

    /*------------------------------------------------------------------------*/
    /*                           Public 404 Operations                        */
    /*------------------------------------------------------------------------*/

    function init404(uint256 unit404Decimals) external  {
        units = 10 ** unit404Decimals;
        _INITIAL_CHAIN_ID = block.chainid;
        _INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
        _MAX_TOKEN_ID = 10_000;
    }

    ///@notice Function for ERC721 setApprovalForAll.
    function setApprovalForAll(address _operator, bool _approved) public virtual {
        require(_operator != address(0), "404: Invalid operator address");
        isApprovedForAll[msg.sender][_operator] = _approved;
        emit ERC721Events.ApprovalForAll(msg.sender, _operator, _approved);
    }

    /// @notice Function for token approvals
    /// @dev This function assumes the operator is attempting to approve
    ///      an ERC-721 if valueOrId_ is a possibly valid ERC-721 token id.
    ///      Unlike setApprovalForAll, spender_ must be allowed to be 0x0 so
    ///      that approval can be revoked.
    /// Note Overrides ERC20's `approve` function.
    function approve(
        address spender_,
        uint256 valueOrId_
    ) public virtual override returns (bool) {
        if (_isValidTokenId(valueOrId_)) {
            erc721Approve(spender_, valueOrId_);
        } else {
            return erc20Approve(spender_, valueOrId_);
        }

        return true;
    }

    /// @notice Function for ERC-20 transfers.
    function transfer(address to_, uint256 value_) public virtual override returns (bool) {
        // Prevent burning tokens to 0x0.
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        _transferERC20(msg.sender, to_, value_);
        return true;
    }

    /// @notice Function for mixed transfers from an operator that may be different than 'from'.
    /// @dev This function assumes the operator is attempting to transfer an ERC-721
    ///      if valueOrId is a possible valid token id.
    function transferFrom(
        address from_,
        address to_,
        uint256 valueOrId_
    ) public virtual override returns (bool) {
        if (_isValidTokenId(valueOrId_)) {
            erc721TransferFrom(from_, to_, valueOrId_);
            erc20TransferFrom(from_, to_, units);   //check?
        } else {
        // Intention is to transfer as ERC-20 token (value).
            return erc20TransferFrom(from_, to_, valueOrId_);
        }

        return true;
    }

    /// @notice Internal function for ERC20 burn
    /// @dev This function will allow burn of ERC20s.
    function burn(uint256 value_) public virtual override {
        _transferERC20(_msgSender(), address(0), value_);
    }

    /// @notice Function for ERC721 transfers from.
    /// @dev Transfers the `id` from `from` to `to`. Emits `ERC721Transfer` events.
    /// Note Recommended use for ERC721 related transfers. Does not handle ERC20 transfers.
    function erc721TransferFrom(
        address from_,
        address to_,
        uint256 id_
    ) public virtual {
        // Prevent minting tokens from 0x0.
        if (from_ == address(0)) {
            revert InvalidSender();
        }

        // Prevent burning tokens to 0x0.
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        //Check `from` is the owner of `id`
        if (from_ != _getOwnerOf(id_)) {
            revert Unauthorized();
        }

        //Check that the operator is either the sender or approved for the transfer.
        //Reverts if the operator is not the sender, not approved for all, and not approved for the transfer
        if (
            msg.sender != from_ &&
            !isApprovedForAll[from_][msg.sender] &&
            msg.sender != getApproved[id_]
        ) {
            revert Unauthorized();
        }

        //Account for changes in ownership and owned arrays
        _transferERC721(from_, to_, id_);
    }

    /// @notice Function for ERC-20 transfers from.
    /// @dev This function is recommended for ERC20 transfers
    function erc20TransferFrom(
        address from_,
        address to_,
        uint256 value_
    ) public virtual returns (bool) {
        // Prevent minting tokens from 0x0.
        if (from_ == address(0)) {
            revert InvalidSender();
        }

        // Prevent burning tokens to 0x0.
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        uint256 allowed = allowance(from_, msg.sender);

        // Check that the operator has sufficient allowance.
        if (allowed != type(uint256).max) {
            _approve(from_, msg.sender, allowed - value_);      // allowance[from_][msg.sender] = allowed - value_;

        }

        return _transferERC20(from_, to_, value_);
    }

    /// @notice Function for ERC721 safeTransferFrom with contract support.
    ///         Only allows safeTransferFrom of valid ERC721 token ids. Cannot be used with ERC20.
    /// Note Recommended for ERC721 transfers that require a safe callback check.
    function safeTransferFrom(
        address from_,
        address to_,
        uint256 id_
    ) public virtual {
        safeTransferFrom(from_, to_, id_, "");
    }

    /// @notice Function for ERC721 safeTransferFrom with contract support and callback data.
    ///        Only allows safeTransferFrom of valid ERC721 token ids. Cannot be used with ERC20.
    /// Note Recommended for ERC721 transfers that require a safe callback check.
    function safeTransferFrom(
        address from_,
        address to_,
        uint256 id_,
        bytes memory data_
    ) public virtual {
        if (!_isValidTokenId(id_)) {
            revert InvalidTokenId();
        }

        transferFrom(from_, to_, id_);

        if (_isContract(to_)) {
            _checkOnERC721Received(from_, to_, id_, data_);
        }
    }

    /// @notice Function for self-exemption
    function mintERC721() public virtual {
        address to_ = _msgSender();
        
        ERC20Storage storage $ = getERC20Storage();
        uint256 tokensToMint = (inactiveBalance(to_) / units);

        $._balances[to_] -= (tokensToMint * units);

        for (uint256 i = 0; i < tokensToMint;) {
            _retrieveOrMintERC721(to_);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Function for EIP-2612 permits
    function permit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) public override {
        if (deadline_ < block.timestamp) {
                revert PermitDeadlineExpired();
            }

        // permit cannot be used for ERC-721 token approvals, so ensure
        // the value does not fall within the valid range of ERC-721 token ids.
        if (_isValidTokenId(value_)) {
            revert InvalidApproval();
        }

        if (spender_ == address(0)) {
            revert InvalidSpender();
        }

        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner_,
                                spender_,
                                value_,
                                _useNonce(owner_),
                                deadline_
                            )
                        )
                    )
                ),
                v_,
                r_,
                s_
            );

            if (recoveredAddress == address(0) || recoveredAddress != owner_) {
                revert InvalidSigner();
            }

            _approve(recoveredAddress, spender_, value_);       // allowance[recoveredAddress][spender_] = value_;
        }

        emit ERC20Events.Approval(owner_, spender_, value_);
    }

    /// @notice Returns domain initial domain separator, or recomputes if chain id is not equal to initial chain id
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return
        block.chainid == _INITIAL_CHAIN_ID
            ? _INITIAL_DOMAIN_SEPARATOR
            : _computeDomainSeparator();
    }

    /// @notice Double check later if this correct
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IPurseERC404).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    /*------------------------------------------------------------------------*/
    /*                          Internal 404 Operations                       */
    /*------------------------------------------------------------------------*/

    /// @notice Function for pure ERC-721 approvals.
    /// @dev Intention is to approve as ERC-721 token (id).
    function erc721Approve(address spender_, uint256 id_) internal virtual {
        address erc721Owner = _getOwnerOf(id_);

        if (msg.sender != erc721Owner && !isApprovedForAll[erc721Owner][msg.sender]) {
            revert Unauthorized();
        }

        getApproved[id_] = spender_;
        emit ERC721Events.Approval(erc721Owner, spender_, id_);
    }

    /// @dev Providing type(uint256).max for approval value results in an
    ///      unlimited approval that is not deducted from on transfers.
    function erc20Approve(address spender_, uint256 value_) internal virtual returns (bool) {
        // Prevent granting 0x0 an ERC-20 allowance.
        if (spender_ == address(0)) {
            revert InvalidSpender();
        }

        _approve(msg.sender, spender_, value_);     // allowance[msg.sender][spender_] = value_;

        emit ERC20Events.Approval(msg.sender, spender_, value_);

        return true;
    }

    /// @notice This is the lowest level ERC-20 transfer function, which
    ///         should be used for both normal ERC-20 transfers as well as minting.
    /// Note that this function allows transfers to and from 0x0.
    function _transferERC20(
        address from_,
        address to_,
        uint256 value_
    ) internal virtual returns(bool) {
        // Minting is a special case for which we should not check the balance of
        // the sender, and we should increase the total supply.
        if (from_ == address(0)) {
            _mint(to_, value_);     //   totalSupply += value_;
        } else {
            if (inactiveBalance(from_) < value_) {
                ERC20Storage storage $ = getERC20Storage();
                uint256 tokensToWithdrawAndStore = (value_ - inactiveBalance(from_) / units) + 1;

                for (uint256 i = 0; i < tokensToWithdrawAndStore;) {
                    _withdrawAndStoreERC721(from_);
                    unchecked {
                        ++i;
                    }
                }

                unchecked {
                    // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                    $._balances[from_] += (tokensToWithdrawAndStore * units);
                } 
            }

            if (to_ == address(0)) {
                _burn(from_, value_);
            } else {
                _transfer(from_, to_, value_);
            }
        }

        emit ERC20Events.Transfer(from_, to_, value_);

        return true;
    }

    /// @notice Internal function for ERC20 minting
    /// @dev This function will allow minting of new ERC20s.
    ///      If mintCorrespondingERC721s_ is true, and the recipient is not ERC-721 exempt, it will
    ///      also mint the corresponding ERC721s.
    /// Handles ERC-721 exemptions.
    function _mintERC20(address to_, uint256 value_) internal virtual {
        /// You cannot mint to the zero address (you can't mint and immediately burn in the same transfer).
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        if (totalSupply() + value_ > ID_ENCODING_PREFIX) {
            revert MintLimitReached();
        }

        _transferERC20(address(0), to_, value_);
        // _transferERC20WithERC721(address(0), to_, value_);
    }

    /// @notice Consolidated record keeping function for transferring ERC-721s.
    /// @dev Assigns the token to the new owner, and removes from the old owner.
    /// Note This function allows transfers to and from 0x0. Does not handle ERC20 transfers.
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

        emit ERC721Events.Transfer(_from, _to, _id);
    }

    /// @notice Internal function for ERC-721 minting and retrieval from the bank.
    /// @dev This function will allow minting of new ERC-721s up to the total fractional supply. It will
    ///      first try to pull from the bank, and if the bank is empty, it will mint a new token.
    /// Does not handle ERC20 balance updates.
    function _retrieveOrMintERC721(address to_) internal virtual {
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        uint256 id;

        if (!_storedERC721Ids.empty()) {
            // If there are any tokens in the bank, use those first.
            // Pop off the end of the queue (FIFO).
            id = _storedERC721Ids.popBack();
        } else {
            // Otherwise, mint a new token, should not be able to go over the total fractional supply.
            ++minted;

            if (minted == _MAX_TOKEN_ID) {
                revert MintLimitReached();
            }

            id = ID_ENCODING_PREFIX + minted;
        }

        address erc721Owner = _getOwnerOf(id);

        // The token should not already belong to anyone besides 0x0 or this contract.
        // If it does, something is wrong, as this should never happen.
        if (erc721Owner != address(0)) {
            revert AlreadyExists();
        }

        // Transfer the NFT to the recipient, either transferring from the contract's bank or minting.
        // Does not handle ERC-721 exemptions.
        _transferERC721(erc721Owner, to_, id);
    }

    /// @notice Internal function for ERC-721 deposits to bank (this contract).
    /// @dev This function will allow depositing of ERC-721s to the bank, which can be retrieved by future minters.
    // Does not handle ERC-721 exemptions.
    function _withdrawAndStoreERC721(address from_) internal virtual {
        if (from_ == address(0)) {
            revert InvalidSender();
        }

        // Retrieve the latest token added to the owner's stack (LIFO).
        uint256 id = _owned[from_][_owned[from_].length - 1];

        // Transfer to 0x0.
        // Does not handle ERC-721 exemptions.
        _transferERC721(from_, address(0), id);

        // Record the token in the contract's bank queue.
        _storedERC721Ids.pushFront(id);
    }

    ///@notice Function for ERC721 _checkOnERC721Received.
    ///@dev Performs a call to {IERC721Receiver-onERC721Received} on `to`.
    ///     Reverts if the target is a contract and does not support the function correctly.
    ///Note Uses assembly to save gas. To be used together with `isContract`.
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


    function getERC20Storage() private pure returns (ERC20Storage storage $) {
        assembly {
            $.slot := ERC20StorageLocation
        }
    }

    /// @notice Function to check if address is transfer exempt
    function erc721TransferExempt(
        address target_
    ) public view virtual returns (bool) {
        return target_ == address(0);     // return target_ == address(0) || _erc721TransferExempt[target_];
    }

    /// @notice Internal function to compute domain separator for EIP-2612 permits
    function _computeDomainSeparator() internal view virtual returns (bytes32) {
        return
        keccak256(
            abi.encode(
            keccak256(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
            ),
            keccak256(bytes(name())),
            keccak256("1"),
            block.chainid,
            address(this)
            )
        );
    }
}