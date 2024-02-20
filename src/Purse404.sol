// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import {Lite404Upgradeable} from "./Lite404Upgradeable.sol";

contract PurseToken is Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, ERC20PausableUpgradeable, AccessControlUpgradeable, ERC20PermitUpgradeable, UUPSUpgradeable, Lite404Upgradeable {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    string public dataURI;
    string public baseTokenURI;

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

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}

    // The following functions are overrides required by Solidity.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        super._update(from, to, value);
    }

    /*------------------------------------------------------------------------*/
    /*                      404 Authorized Only Functions                     */
    /*------------------------------------------------------------------------*/

    function updateBaseValue(uint256 _value) external onlyRole(UPGRADER_ROLE) {
        require(_value > 0, "PurseToken: base value must be greater than 0");
        base = _value;
        emit BaseValueUpdated(_value);
    }

    ///@dev The default is 10,000 token ids
    function updateMaxTokenID(uint256 _maxTokenID) external onlyRole(UPGRADER_ROLE) {
        require(_maxTokenID > 0, "PurseToken: max token ID must be greater than 0");
        _MAX_TOKEN_ID = _maxTokenID;
        emit MaxTokenIdUpdated(_maxTokenID);
    }

    /*------------------------------------------------------------------------*/
    /*                Overrides From ERC20 to 404 Implementation              */
    /*------------------------------------------------------------------------*/

    function tokenURI(uint256 id_) public pure override returns (string memory) {
        return string.concat("https://example.com/token/", Strings.toString(id_));
    }

    function approve(
        address spender, 
        uint256 value
    ) public override(ERC20Upgradeable, Lite404Upgradeable) returns (bool) {
        return Lite404Upgradeable.approve(spender, value);
    }

    function mint(address to, uint256 amount) public override(Lite404Upgradeable) onlyRole(MINTER_ROLE) {
        Lite404Upgradeable.mint(to, amount);
    }

    function transfer(
        address to, 
        uint256 value
    ) public override(ERC20Upgradeable, Lite404Upgradeable) returns (bool) {
        return Lite404Upgradeable.transfer(to, value);
    }

    function transferFrom(
        address from, 
        address to, 
        uint256 value
    ) public override(ERC20Upgradeable, Lite404Upgradeable) returns (bool) {
        return Lite404Upgradeable.transferFrom(from, to, value);
    }
}