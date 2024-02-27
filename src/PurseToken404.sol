// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {InheritERC404} from "./InheritERC404.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @custom:oz-upgrades-from PurseToken
contract PurseToken404 is InheritERC404 {

    function mint(
        address account_,
        uint256 value_
    ) public override onlyRole(MINTER_ROLE) {
        _mintERC20(account_, value_);
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        string memory baseURI = _baseURI();
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, Strings.toString(tokenId))) : "";
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}