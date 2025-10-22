
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract NFTCollection is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using Strings for uint256;

    uint256 public immutable maxSupply;
    uint256 public immutable maxPerWallet;
    uint256 public mintPrice;
    string  private baseURI_;
    bool    public saleEnabled;

    uint256 private _nextId = 1;
    mapping(address => uint256) public mintedBy;

    event BaseURISet(string baseURI);
    event SaleEnabled(bool enabled);
    event Minted(address indexed minter, uint256 quantity, uint256 firstTokenId);
    event Withdraw(address indexed to, uint256 amount);
    event MintPriceSet(uint256 mintPrice);
    event MaxPerWalletWarning(uint256 maxPerWallet);

    constructor(
        string memory name_,
        string memory symbol_,
        address royaltyReceiver,
        uint96  royaltyBps,
        uint256 mintPrice_,
        uint256 maxPerWallet_,
        uint256 maxSupply_,
        string memory baseURI__
    ) ERC721(name_, symbol_) Ownable(msg.sender) {
        require(maxSupply_ > 0, "maxSupply=0");
        require(royaltyBps <= 10_000, "royalty>100%");
        maxSupply = maxSupply_;
        maxPerWallet = maxPerWallet_;
        mintPrice = mintPrice_;
        baseURI_ = baseURI__;
        _setDefaultRoyalty(royaltyReceiver, royaltyBps);
        emit MintPriceSet(mintPrice);
        if (maxPerWallet_ == 0) {
            emit MaxPerWalletWarning(0);
        }
    }

    // --- Mint ---
    function setSaleEnabled(bool enabled) external onlyOwner {
        saleEnabled = enabled;
        emit SaleEnabled(enabled);
    }

    function setMintPrice(uint256 _mintPrice) external onlyOwner {
        mintPrice = _mintPrice;
        emit MintPriceSet(_mintPrice);
    }

    function setBaseURI(string calldata _baseURI) external onlyOwner {
        baseURI_ = _baseURI;
        emit BaseURISet(_baseURI);
    }

    function mint(uint256 quantity) external payable nonReentrant {
        require(saleEnabled, "sale disabled");
        require(quantity > 0, "qty=0");
        require(_nextId + quantity - 1 <= maxSupply, "exceeds maxSupply");
        if (maxPerWallet > 0) {
            require(mintedBy[msg.sender] + quantity <= maxPerWallet, "wallet cap");
        }
        uint256 totalCost = mintPrice * quantity;
        require(msg.value == totalCost, "wrong value");

        uint256 firstId = _nextId;
        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(msg.sender, _nextId++);
        }
        mintedBy[msg.sender] += quantity;
        emit Minted(msg.sender, quantity, firstId);
    }

    function ownerMint(address to, uint256 quantity) external onlyOwner {
        require(quantity > 0, "qty=0");
        require(_nextId + quantity - 1 <= maxSupply, "exceeds maxSupply");
        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(to, _nextId++);
        }
    }

    // --- Withdraw (mint proceeds) ---
    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "withdraw fail");
        emit Withdraw(to, amount);
    }

    // --- Metadata ---
    function _baseURI() internal view override returns (string memory) {
        return baseURI_;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory base = _baseURI();
        return bytes(base).length > 0 ? string(abi.encodePacked(base, tokenId.toString())) : "";
    }

    // --- ERC165 ---
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
