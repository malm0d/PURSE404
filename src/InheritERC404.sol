// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IPurseERC404} from "./interfaces/IPurseERC404.sol";
import {DoubleEndedQueue} from "./lib/DoubleEndedQueue.sol";
import {ERC721Events} from "./lib/ERC721Events.sol";
import {ERC20Events} from "./lib/ERC20Events.sol";
import {PurseToken} from "./PurseToken.sol";

abstract contract InheritERC404 is PurseToken, IPurseERC404 {
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;

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

    /// @dev Packed representation of ownerOf and owned indices
    mapping(uint256 => OwnedData) internal _ownedData;

    /// @dev Array of owned ids in ERC-721 representation
    mapping(address => uint256[]) internal _owned;

    /// @dev Constant for token id encoding
    uint256 public constant ID_ENCODING_PREFIX = 1 << 255;

    /// @dev tokenURI for 721Metadata
    string public baseTokenURI;

    uint256 internal _MAX_TOKEN_ID;   // set constant for Max?

    /// @dev Packed representation of ownerOf and owned indices
    struct OwnedData {
        address ownerOf;
        uint96 ownedIndex;
    }

    /************************************
    /******** 404 functions *************
    *************************************/
    function erc721Approve(address spender_, uint256 id_) public virtual {
        // Intention is to approve as ERC-721 token (id).
        address erc721Owner = _getOwnerOf(id_);

        if (
            msg.sender != erc721Owner && !isApprovedForAll[erc721Owner][msg.sender]
        ) {
            revert Unauthorized();
        }

        getApproved[id_] = spender_;

        emit ERC721Events.Approval(erc721Owner, spender_, id_);
    }

    /// @dev Providing type(uint256).max for approval value results in an
    ///      unlimited approval that is not deducted from on transfers.
    function erc20Approve(
        address spender_,
        uint256 value_
    ) public virtual returns (bool) {
        // Prevent granting 0x0 an ERC-20 allowance.
        // if (spender_ == address(0)) {
        //     revert InvalidSpender();
        // }

        _approve(msg.sender, spender_, value_);

        return true;
    }

    /// @notice Function for ERC-721 transfers from.
    /// @dev This function is recommended for ERC721 transfers.
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

        if (from_ != _getOwnerOf(id_)) {
            revert Unauthorized();
        }

        // Check that the operator is either the sender or approved for the transfer.
        if (
            msg.sender != from_ &&
            !isApprovedForAll[from_][msg.sender] &&
            msg.sender != getApproved[id_]
        ) {
            revert Unauthorized();
        }

        // Transfer 1 * units ERC-20 and 1 ERC-721 token.
        // ERC-721 transfer exemptions handled above. Can't make it to this point if either is transfer exempt.
        _transferERC721WithERC20(from_, to_, id_);
        // Add ERC-20 event tomake sure transfer event amount is tally with user balance
        emit ERC20Events.Transfer(from_, to_, units);
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

        _spendAllowance(from_, msg.sender, value_);

        // Transferring ERC-20s directly requires the _transferERC20 function.
        // Handles ERC-721 exemptions internally.
        return _transferERC20(from_, to_, value_);
    }

    /// @notice Function for mint 721
    function mintERC721() public virtual {
        address to_ = _msgSender();
        if(inactiveBalance(to_) < units) {
            revert InsufficientInactiveBalance();
        }
        
        ERC20Storage storage $ = _getERC20Storages();
        uint256 tokenUserAbleToMint= (inactiveBalance(to_) / units);
        uint256 tokenAvailableToMint = _MAX_TOKEN_ID + getERC721QueueLength() - minted;

        uint256 tokensToMint = 
            (tokenUserAbleToMint > tokenAvailableToMint) ? 
            tokenAvailableToMint : tokenUserAbleToMint;

        //If no tokens to mint, then the limit is reached
        if (tokensToMint == 0) {
            revert MintLimitReached();
        }

        $._balances[to_] -= (tokensToMint * units);

        for (uint256 i = 0; i < tokensToMint;) {
            _retrieveOrMintERC721(to_);
            unchecked {
                ++i;
            }
        }
    }

    /************************************
    /******** ERC-20 functions **********
    *************************************/
    /// @notice Function for token approvals
    /// @dev This function assumes the operator is attempting to approve
    ///      an ERC-721 if valueOrId_ is a possibly valid ERC-721 token id.
    ///      Unlike setApprovalForAll, spender_ must be allowed to be 0x0 so
    ///      that approval can be revoked.
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
        } else {
        // Intention is to transfer as ERC-20 token (value).
            return erc20TransferFrom(from_, to_, valueOrId_);
        }

        return true;
    }

    /// @notice Function for ERC-20 transfers.
    /// @dev This function assumes the operator is attempting to transfer as ERC-20
    ///      given this function is only supported on the ERC-20 interface.
    ///      Treats even large amounts that are valid ERC-721 ids as ERC-20s.
    function transfer(address to_, uint256 value_) public virtual override returns (bool) {
        // Prevent burning tokens to 0x0.
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        // Transferring ERC-20s directly requires the _transfer function.
        // Handles ERC-721 exemptions internally.
        return _transferERC20(msg.sender, to_, value_);
    }

    /**
     * @dev Destroys a `value` amount of tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 value_) public virtual override {
        _transferERC20(_msgSender(), address(0), value_);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, deducting from
     * the caller's allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `value`.
     */
    function burnFrom(address account, uint256 value_) public virtual override {
        _spendAllowance(account, _msgSender(), value_);
        _transferERC20(account, address(0), value_);
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

            _approve(recoveredAddress, spender_, value_);
        }
    }
    
    /// @notice Returns domain initial domain separator, or recomputes if chain id is not equal to initial chain id
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return
        block.chainid == _INITIAL_CHAIN_ID
            ? _INITIAL_DOMAIN_SEPARATOR
            : _computeDomainSeparator();
    }

    /// @notice Double check later if this correct - CK
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IPurseERC404).interfaceId ||
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    /************************************
     ******** ERC-721 functions *********
     ************************************/

    /// @notice Function for ERC-721 approvals
    function setApprovalForAll(address operator_, bool approved_) public virtual {
        // Prevent approvals to 0x0.
        if (operator_ == address(0)) {
            revert InvalidOperator();
        }
        isApprovedForAll[msg.sender][operator_] = approved_;
        emit ERC721Events.ApprovalForAll(msg.sender, operator_, approved_);
    }

    /// @notice Function for ERC-721 transfers with contract support.
    /// This function only supports moving valid ERC-721 ids, as it does not exist on the ERC-20 spec and will revert otherwise.
    function safeTransferFrom(
        address from_,
        address to_,
        uint256 id_
    ) public virtual {
        safeTransferFrom(from_, to_, id_, "");
    }

    /// @notice Function for ERC-721 transfers with contract support and callback data.
    /// This function only supports moving valid ERC-721 ids, as it does not exist on the ERC-20 spec and will revert otherwise.
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
        _checkOnERC721Received(from_, to_, id_, data_);
    }

    /************************************
     ******** Internal functions ********
     ************************************/

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
            _mint(to_, value_);
        } else {
            if (inactiveBalance(from_) < value_ && erc721BalanceOf(from_) > 0) {
                ERC20Storage storage $ = _getERC20Storages();
                uint256 diffInValue = value_ - inactiveBalance(from_);
                uint256 tokensToWithdrawAndStore = diffInValue / units + (diffInValue % units == 0 ? 0 : 1);

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

        return true;
    }

    /// @notice Consolidated record keeping function for transferring ERC-721s.
    /// @dev Assign the token to the new owner, and remove from the old owner.
    /// Note that this function allows transfers to and from 0x0.
    /// Does not handle ERC-721 exemptions.
    function _transferERC721WithERC20(
        address from_,
        address to_,
        uint256 id_
    ) internal virtual {
        // If this is not a mint, handle record keeping for transfer from previous owner.
        if (from_ != address(0)) {
            // On transfer of an NFT, any previous approval is reset.
            delete getApproved[id_];

            uint256 updatedId = _owned[from_][_owned[from_].length - 1];
            if (updatedId != id_) {
                uint96 updatedIndex = _getOwnedIndex(id_);
                // update _owned for sender
                _owned[from_][updatedIndex] = updatedId;
                // update index for the moved id
                _setOwnedIndex(updatedId, updatedIndex);
            }

            // pop
            _owned[from_].pop();
        }

        // Check if this is a burn.
        if (to_ != address(0)) {
            // If not a burn, update the owner of the token to the new owner.
            // Update owner of the token to the new owner.
            _setOwnerOf(id_, to_);
            // Push token onto the new owner's stack.
            _owned[to_].push(id_);
            // Update index for new owner's stack.
            _setOwnedIndex(id_, uint96(_owned[to_].length - 1));
        } else {
            // If this is a burn, reset the owner of the token to 0x0 by deleting the token from _ownedData.
            delete _ownedData[id_];
        }

        //emit ERC721Events.Transfer(from_, to_, id_);
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
    }

    /// @notice Internal function for ERC-721 minting and retrieval from the bank.
    /// @dev This function will allow minting of new ERC-721s up to the total fractional supply. It will
    ///      first try to pull from the bank, and if the bank is empty, it will mint a new token.
    /// Does not handle ERC-721 exemptions.
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

            // Reserve max uint256 for approvals
            if (minted > ID_ENCODING_PREFIX + _MAX_TOKEN_ID) {
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

        // Transfer the token to the recipient, either transferring from the contract's bank or minting.
        // Does not handle ERC-721 exemptions.
        _transferERC721WithERC20(erc721Owner, to_, id);
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
        _transferERC721WithERC20(from_, address(0), id);

        // Record the token in the contract's bank queue.
        _storedERC721Ids.pushFront(id);
    }

    /**
     * @dev Private function to invoke {IERC721Receiver-onERC721Received} on a target address. This will revert if the
     * recipient doesn't accept the token transfer. The call is not executed if the target address is not a contract.
     *
     * @param from address representing the previous owner of the given token ID
     * @param to target address that will receive the tokens
     * @param tokenId uint256 ID of the token to be transferred
     * @param data bytes optional data to send along with the call
     */
    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(_msgSender(), from, tokenId, data) returns (bytes4 retval) {
                if (retval != IERC721Receiver.onERC721Received.selector) {
                    revert ERC721InvalidReceiver(to);
                }
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert ERC721InvalidReceiver(to);
                } else {
                    /// @solidity memory-safe-assembly
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        }
    }

    function _getERC20Storages() private pure returns (ERC20Storage storage $) {
        assembly {
            $.slot := 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00
        }
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

    /// @notice For a token token id to be considered valid, it just needs
    ///         to fall within the range of possible token ids, it does not
    ///         necessarily have to be minted yet.
    function _isValidTokenId(uint256 id_) internal view returns (bool) {
        return id_ > ID_ENCODING_PREFIX && id_ <= ID_ENCODING_PREFIX + _MAX_TOKEN_ID;
    }

    function _getOwnerOf(
        uint256 id_
    ) internal view virtual returns (address ownerOf_) {
        return _ownedData[id_].ownerOf;
    }

    function _setOwnerOf(uint256 id_, address owner_) internal virtual {
        _ownedData[id_].ownerOf = owner_;
    }

    function _getOwnedIndex(
        uint256 id_
    ) internal view virtual returns (uint96 ownedIndex_) {
        return _ownedData[id_].ownedIndex;
    }

    function _setOwnedIndex(uint256 id_, uint96 index_) internal virtual {
        _ownedData[id_].ownedIndex = index_;
    }

    /**
     * @dev Returns whether `tokenId` exists.
     *
     * Tokens can be managed by their owner or approved accounts via {approve} or {setApprovalForAll}.
     *
     * Tokens start existing when they are minted (`_mint`),
     * and stop existing when they are burned (`_burn`).
     */
    function _exists(uint256 tokenId) internal view virtual returns (bool) {
        return _getOwnerOf(tokenId) != address(0);
    }

    function _baseURI() internal view virtual returns (string memory) {
        return baseTokenURI;
    }

    /************************************
     ******** Public View functions *****
     ************************************/

    /// @dev See {IERC20-balanceOf}.
    function balanceOf(address account) public view override returns (uint256) {
        return inactiveBalance(account) + activeBalance(account);
    }

    /// @notice tokenURI must be implemented by child contract
    function tokenURI(uint256 id_) public view virtual returns (string memory);

    /// @dev Nonconverted-721 ERC20 balance.
    function inactiveBalance(address account) public view virtual returns (uint256) {
        ERC20Storage storage $ = _getERC20Storages();
        return $._balances[account];
    }

    /// @dev converted-721 ERC20 balance.
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

    function owned(
        address owner_
    ) public view virtual returns (uint256[] memory) {
        return _owned[owner_];
    }

    function erc721BalanceOf(
        address owner_
    ) public view virtual returns (uint256) {
        return _owned[owner_].length;
    }

    function erc721TotalSupply() public view virtual returns (uint256) {
        return minted;
    }

    function erc721MaxTokenId() public view virtual returns (uint256) {
        return ID_ENCODING_PREFIX + _MAX_TOKEN_ID;
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

    /************************************
     ******** Admin functions ***********
     ************************************/

    function init404(uint256 unit404Decimals) external onlyRole(DEFAULT_ADMIN_ROLE) {
        units = 10 ** unit404Decimals;
        _INITIAL_CHAIN_ID = block.chainid;
        _INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    function setMaxTokenId(uint256 _cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_cap > minted, "Less than minted");
        _MAX_TOKEN_ID = _cap;
    }

    function setBaseURI(string memory baseURI) public onlyRole(DEFAULT_ADMIN_ROLE) {
        baseTokenURI = baseURI;
    }
}