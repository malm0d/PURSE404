// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract PurseToken is Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, ERC20PausableUpgradeable, AccessControlUpgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    /*------------------------------------------------------------------------*/
    /*                                 Storage                                */
    /*------------------------------------------------------------------------*/

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    bytes32 private constant ERC20StorageLocation = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    ///@dev Balance for NFTs: is always a whole number
    mapping(address account => uint256) activeBalances;

    ///@notice Denotes the amount of ERC20s required for 1 NFT
    ///@dev A function to allow only the owner/administrator to update this value is required
    ///     in the inheriting contract.
    uint256 public base;

    ///@dev Token id prefix. This is the same as: 2 ** 255.
    ///Note Every token id will be represented as: ID_ENCODING_PREFIX + id
    ///     This allows for a simple way to differentiate between ERC20 and ERC721 tokens,
    ///     and allows 2 ** 255 - 1 token ids to be minted.
    uint256 public constant ID_ENCODING_PREFIX = 1 << 255;

    ///@dev A function to allow only the owner/administrator to update this value is required
    ///     in the inheriting contract.
    uint256 internal _MAX_TOKEN_ID = 10_000;

    ///@dev Current mint counter, which is also highest minted token id.
    //      Also regarded as the total supply of minted NFTs
    uint256 internal _mintedNFTSupply;

    ///@dev Divisor for rounding to the nearest whole number
    uint256 internal constant ADJUSTMENT_FACTOR = 10 ** 18;

    ///@dev Approvals in ERC721
    mapping(uint256 => address) public getApproved;

    ///@dev Approval for all ERC721
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    ///@dev Array of owned ids in ERC721
    mapping(address => uint256[]) internal _owned;

    ///@dev Packed representation of ownerOf and owned indices
    struct OwnedData {
        address ownerOf;
        uint96 ownedIndex;
    }
    mapping(uint256 => OwnedData) internal _ownedData;

    /*------------------------------------------------------------------------*/
    /*                                 Events                                 */
    /*------------------------------------------------------------------------*/

    event ERC721Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event ERC721Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event BaseValueUpdated(uint256 newValue);
    event MaxTokenIdUpdated(uint256 newValue);

    /*------------------------------------------------------------------------*/
    /*                              Custom Errors                             */
    /*------------------------------------------------------------------------*/

    error NotFound();
    error AlreadyExists();
    error InvalidId();
    error InvalidRecipient();
    error InvalidSender();
    error InvalidExemption();
    error Unauthorized();
    error ERC721MintLimitReached();
    error ERC721InsufficientBalance();

    /*------------------------------------------------------------------------*/
    /*                               Initializer                              */
    /*------------------------------------------------------------------------*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address defaultAdmin, address pauser, address minter, address upgrader)
        initializer public
    {
        __ERC20_init("PURSE TOKEN", "PURSE");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __ERC20Permit_init("PURSE TOKEN");
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, pauser);
        _mint(msg.sender, 10000000000 * 10 ** decimals());
        _grantRole(MINTER_ROLE, minter);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    /*------------------------------------------------------------------------*/
    /*                             Only Authorized                            */
    /*------------------------------------------------------------------------*/

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function getERC20Storage() private pure returns (ERC20Storage storage $) {
        assembly {
            $.slot := ERC20StorageLocation
        }
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}

    /*------------------------------------------------------------------------*/
    /*                             View Operations                            */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Returns the total balance of the account.
     * @dev See {IERC20-balanceOf}.
     *      Returns the sum of all active and inactive balances.
     * Note Active balances are ERC20s reserved for NFTs, and are always a whole number.
     *      Inactive balances are ERC20s that can be fractional. 
     */
    function balanceOf(address account) public view override returns (uint256) {
        return inactiveBalance(account) + activeBalances[account];
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function inactiveBalance(address account) public view virtual returns (uint256) {
        ERC20Storage storage $ = getERC20Storage();
        return $._balances[account];
    }

    ///@notice Returns the erc721 balance of `_owner`.
    function activeBalance(address _owner) public view virtual returns (uint256) {
        return (_owned[_owner].length * base);
    }

    function tokenURI(uint256 id) public view virtual returns (string memory) {}

    ///@notice Returns the total supply of minted NFTs.
    function totalSupplyERC721() public view virtual returns (uint256) {
        return _mintedNFTSupply;
    }

    /*------------------------------------------------------------------------*/
    /*                        External/Public Operation                       */
    /*------------------------------------------------------------------------*/

    ///@notice Function mixed approvals: ERC20 and ERC721, depending on `_valueOrId`.
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

    ///@notice Function for ERC721 specific setApprovalForAll.
    function setApprovalForAll(address _operator, bool _approved) public virtual {
        require(_operator != address(0), "404: Invalid operator address");
        isApprovedForAll[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    function transfer(address _to, uint256 _value) public override returns (bool) {}

    function transferFrom(address _from, address _to, uint256 _value) public override returns (bool) {}

    ///@notice Function for ERC20 mint
    ///@dev Only mints ERC20s to the recipient. The minted amount will be added to the recipient's
    ///     inactive balance. No NFT(s) will be minted in this function.
    function mint(address _to, uint256 _amount) public onlyRole(MINTER_ROLE) {
        _mint(_to, _amount);
    }

    ///@notice Function for ERC20 burn with NFTs in context
    ///@dev Burns ERC20s from the caller's balance, this burns the equivalent amount of NFTs
    ///     from the caller's NFT balance.
    ///note Cannot burn ERC20s from the zero address.
    function burn(address _from, uint256 _value) public {}

    function mintNFT(address _account) public returns (uint256) {}

    function burnNft(address _account) public {} 

    /*------------------------------------------------------------------------*/
    /*                       Internal/Private Operation                       */
    /*------------------------------------------------------------------------*/

    ///@notice Function for ERC20 `_update`
    ///@dev The following functions are overrides required by Solidity.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        super._update(from, to, value);
    }

    /// @notice This is the lowest level ERC-20 transfer function, which
    ///         should be used for both normal ERC-20 transfers as well as minting.
    /// Note that this function allows transfers to and from 0x0.
    // function _transferERC20(
    //     address from_,
    //     address to_,
    //     uint256 value_
    // ) internal virtual {
    //     // Minting is a special case for which we should not check the balance of
    //     // the sender, and we should increase the total supply.
    //     if (from_ == address(0)) {
    //         _mint(to_, value_);     //   totalSupply += value_;
    //     } else {
    //         ERC20Storage storage $ = getERC20Storage();
    //         if (inactiveBalance(from_) < value_) {
    //             uint256 tokensToWithdrawAndStore = (value_ - inactiveBalance(from_) / units) + 1;

    //             for (uint256 i = 0; i < tokensToWithdrawAndStore;) {
    //                 _withdrawAndStoreERC721(from_); //assuming burn from active balance
    //                 unchecked {
    //                     ++i;
    //                 }
    //             }

    //             unchecked {
    //                 // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
    //                 $._balances[from_] += (tokensToWithdrawAndStore * units);
    //             } 
    //         }
    //         _transfer(from_, to_, value_); //cant have to_ as zero addr


    //         _update(from_, to_, value_);
    //     }

    //     emit Transfer(from_, to_, value_);
    // }

    ///@notice Pure ERC721 transfer.
    ///@dev Assign token to new owner, remove from old owner.
    ///note Transfers to and from 0x00 are allowed.
    ///     IMPT: Function for balance updates MUST be handled together with this function.
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

    ///@notice Internal function for pure ERC721 mint.
    ///@dev Does not allow minting to the zero address.
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

    ///@notice Internal function for pure ERC721 Burn.
    ///@dev Burns the last token id in the owned array of `_owner`.
    ///     Does not allow burning from the zero address.
    ///note Burning is a transfer to the zero address.
    function _burnERC721(address _from) internal virtual {
        require(_from != address(0), "404: Zero address");
        uint256 _id = _owned[_from][_owned[_from].length - 1];
        _transferERC721(_from, address(0), _id);
    }

    ///@notice Function for ERC721 `_checkOnERC721Received`.
    ///@dev Performs a call to {IERC721Receiver-onERC721Received} on `to`.
    ///     Reverts if the target is a contract and does not support the function correctly.
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

    ///@dev Get the owner of a token id.
    function _getOwnerOf(uint256 id) internal view virtual returns (address) {
        return _ownedData[id].ownerOf;
    }

    ///@dev Set the owner of a token id.
    function _setOwnerOf(uint256 id, address owner) internal virtual {
        _ownedData[id].ownerOf = owner;
    }

    ///@dev Get the owned index of a token id.
    function _getOwnedIndex(uint256 id) internal view virtual returns (uint96) {
        return _ownedData[id].ownedIndex;
    }

    ///@dev Set the owned index of a token id.
    function _setOwnedIndex(uint256 id, uint96 index) internal virtual {
        _ownedData[id].ownedIndex = index;
    }
}