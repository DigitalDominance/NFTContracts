// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

/**
 * @title NFTCollection
 * @dev Simple, non-upgradeable ERC721 + ERC2981 collection with owner-controlled minting.
 * Default royalty is set in basis points (royalty capped by Marketplace).
 */
contract NFTCollection is ERC721, ERC721URIStorage, ERC2981, Ownable {
    uint256 public nextTokenId;
    string public baseURI;

    constructor(
        string memory name_,
        string memory symbol_,
        address royaltyReceiver,
        uint96 royaltyBps
    ) ERC721(name_, symbol_) Ownable(msg.sender) {
        if (royaltyBps > 10000) revert();
        _setDefaultRoyalty(royaltyReceiver, royaltyBps);
    }

    function safeMint(address to, string memory tokenURI_) external onlyOwner returns (uint256 tokenId) {
        tokenId = ++nextTokenId;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setBaseURI(string memory _base) external onlyOwner {
        baseURI = _base;
    }

    // --- Overrides ---
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }
function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC2981, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return ERC721URIStorage.tokenURI(tokenId);
    }
}
