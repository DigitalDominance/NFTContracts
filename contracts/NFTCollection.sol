// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title NFTCollection
 * @dev ERC721 + ERC2981 collection with public minting.
 * - Deployer sets: mintPrice, maxPerWallet, maxSupply, baseURI.
 * - Public mint enforces: saleEnabled, supply cap, per-wallet cap, exact payment.
 * - Owner can: toggle sale, set mint price, set maxPerWallet, set baseURI, withdraw funds.
 */
contract NFTCollection is ERC721, ERC2981, Ownable {
    using Strings for uint256;

    // ---- Mint config ----
    uint256 public mintPrice;       // in wei (KAS has 18 decimals)
    uint256 public maxPerWallet;
    uint256 public maxSupply;
    bool    public saleEnabled;

    // ---- Accounting ----
    uint256 public nextTokenId;
    string  public baseURI;
    mapping(address => uint256) public mintedPerWallet;

    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event MaxPerWalletUpdated(uint256 oldMax, uint256 newMax);
    event SaleStateUpdated(bool enabled);
    event BaseURIUpdated(string newBaseURI);

    constructor(
        string memory name_,
        string memory symbol_,
        address royaltyReceiver,
        uint96 royaltyBps,
        uint256 mintPrice_,
        uint256 maxPerWallet_,
        uint256 maxSupply_,
        string memory baseURI_
    ) ERC721(name_, symbol_) Ownable(msg.sender) {
        require(maxSupply_ > 0, "maxSupply=0");
        _setDefaultRoyalty(royaltyReceiver, royaltyBps);
        mintPrice = mintPrice_;
        maxPerWallet = maxPerWallet_;
        maxSupply = maxSupply_;
        baseURI = baseURI_;
        saleEnabled = false; // start paused; owner can enable
    }

    // ---------------- Owner controls ----------------

    function setMintPrice(uint256 newPrice) external onlyOwner {
        emit MintPriceUpdated(mintPrice, newPrice);
        mintPrice = newPrice;
    }

    function setMaxPerWallet(uint256 newMax) external onlyOwner {
        require(newMax > 0, "maxPerWallet=0");
        emit MaxPerWalletUpdated(maxPerWallet, newMax);
        maxPerWallet = newMax;
    }

    function setBaseURI(string calldata _base) external onlyOwner {
        baseURI = _base;
        emit BaseURIUpdated(_base);
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setSaleEnabled(bool enabled) external onlyOwner {
        saleEnabled = enabled;
        emit SaleStateUpdated(enabled);
    }

    // Optional owner mint (e.g., reserves/airdrops)
    function ownerMint(address to, uint256 quantity) external onlyOwner returns (uint256 firstTokenId) {
        require(quantity > 0, "qty=0");
        require(nextTokenId + quantity <= maxSupply, "exceeds supply");
        firstTokenId = nextTokenId + 1;
        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(to, ++nextTokenId);
        }
    }

    // ---------------- Public mint ----------------

    /**
     * @notice Mint `quantity` tokens.
     * Requirements:
     * - saleEnabled must be true
     * - exact payment: msg.value == mintPrice * quantity
     * - does not exceed maxSupply
     * - does not exceed maxPerWallet for msg.sender
     */
    function mint(uint256 quantity) external payable returns (uint256 firstTokenId) {
        require(saleEnabled, "sale disabled");
        require(quantity > 0, "qty=0");
        require(msg.value == mintPrice * quantity, "wrong value");

        // Supply & wallet caps
        require(nextTokenId + quantity <= maxSupply, "exceeds supply");
        uint256 minted = mintedPerWallet[msg.sender];
        require(minted + quantity <= maxPerWallet, "exceeds wallet limit");

        // Effects
        mintedPerWallet[msg.sender] = minted + quantity;

        // Mint loop
        firstTokenId = nextTokenId + 1;
        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(msg.sender, ++nextTokenId);
        }
    }

    // ---------------- View & URI ----------------

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    // Compose "<baseURI><tokenId>.json"
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory base = _baseURI();
        return bytes(base).length > 0 ? string(abi.encodePacked(base, tokenId.toString(), ".json")) : "";
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ---------------- Withdraw ----------------

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }
}
