// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

interface ICollectionFactory {
    function getPool(address collection) external view returns (address);
}

error NotOwner();
error NotListed();
error AlreadyListed();
error PaymentTokenNotAllowed();
error InvalidPrice();
error TransferFailed();

contract Marketplace is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant BPS_DENOM = 10_000;

    struct Listing {
        address seller;
        uint256 price;
        address paymentToken; // address(0) = native KAS
        bool active;
    }

    mapping(address => mapping(uint256 => Listing)) public listings;
    mapping(address => bool) public approvedPaymentToken;

    address public treasury;
    address public stakingPool; // legacy single-pool (fallback only)
    uint16 public platformFeeBP;
    uint16 public stakingFeeBP;
    uint16 public royaltyCapBP;

    // per-collection registry
    address public factory;

    event Listed(address indexed nft, uint256 indexed tokenId, address indexed seller, uint256 price, address paymentToken);
    event Cancelled(address indexed nft, uint256 indexed tokenId, address indexed seller);
    event Bought(
        address indexed nft,
        uint256 indexed tokenId,
        address indexed buyer,
        address seller,
        uint256 price,
        address paymentToken,
        uint256 royaltyAmount,
        uint256 stakingFee,
        uint256 platformFee
    );
    event TreasuryUpdated(address indexed treasury);
    event PaymentTokenSet(address indexed token, bool allowed);
    event FactoryUpdated(address indexed factory);

    function initialize(
        address owner_,
        address treasury_,
        address stakingPool_,
        uint16 platformFeeBP_,
        uint16 stakingFeeBP_,
        uint16 royaltyCapBP_
    ) public initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        if (treasury_ == address(0)) revert TransferFailed();
        treasury = treasury_;
        stakingPool = stakingPool_;
        platformFeeBP = platformFeeBP_;
        stakingFeeBP = stakingFeeBP_;
        royaltyCapBP = royaltyCapBP_;

        // Native KAS allowed by default
        approvedPaymentToken[address(0)] = true;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // --- admin ---

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert TransferFailed();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setPaymentToken(address token, bool allowed) external onlyOwner {
        approvedPaymentToken[token] = allowed;
        emit PaymentTokenSet(token, allowed);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "factory=0");
        factory = _factory;
        emit FactoryUpdated(_factory);
    }

    // --- internals ---

    function _ensureNotStaked(address nft, uint256 tokenId) internal view {
        address pool = address(0);
        if (factory != address(0)) {
            pool = ICollectionFactory(factory).getPool(nft);
            if (pool != address(0)) {
                (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("isStaked(uint256)", tokenId));
                require(ok && data.length >= 32, "stake check failed");
                bool st = abi.decode(data, (bool));
                require(!st, "token is staked");
                return;
            }
        }
        // fallback to legacy shared pool (signature: isStaked(address,uint256))
        if (stakingPool != address(0)) {
            (bool ok2, bytes memory data2) = stakingPool.staticcall(abi.encodeWithSignature("isStaked(address,uint256)", nft, tokenId));
            require(ok2 && data2.length >= 32, "stake check failed");
            bool st2 = abi.decode(data2, (bool));
            require(!st2, "token is staked");
        }
    }

    // --- listing ---

    function list(address nft, uint256 tokenId, uint256 price, address paymentToken) external whenNotPaused nonReentrant {
        if (price == 0) revert InvalidPrice();
        if (listings[nft][tokenId].active) revert AlreadyListed();
        if (IERC721(nft).ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (!approvedPaymentToken[paymentToken]) revert PaymentTokenNotAllowed();
        _ensureNotStaked(nft, tokenId);

        listings[nft][tokenId] = Listing({
            seller: msg.sender,
            price: price,
            paymentToken: paymentToken,
            active: true
        });

        emit Listed(nft, tokenId, msg.sender, price, paymentToken);
    }

    function cancel(address nft, uint256 tokenId) external whenNotPaused nonReentrant {
        Listing memory L = listings[nft][tokenId];
        if (!L.active) revert NotListed();
        if (L.seller != msg.sender) revert NotOwner();

        delete listings[nft][tokenId];
        emit Cancelled(nft, tokenId, msg.sender);
    }

    function buy(address nft, uint256 tokenId) external payable whenNotPaused nonReentrant {
        Listing memory L = listings[nft][tokenId];
        if (!L.active) revert NotListed();

        // checks
        address seller = L.seller;
        require(seller != address(0), "bad seller");
        require(seller != msg.sender, "self buy");
        require(IERC721(nft).ownerOf(tokenId) == seller, "seller not owner");

        // fee math
        uint256 price = L.price;
        (uint256 royaltyAmount, address royaltyRecipient) = _royalty(nft, tokenId, price);
        uint256 stakingFee = (price * uint256(stakingFeeBP)) / BPS_DENOM;
        uint256 platformFee = (price * uint256(platformFeeBP)) / BPS_DENOM;
        uint256 sellerProceeds = price - royaltyAmount - stakingFee - platformFee;

        // effects
        delete listings[nft][tokenId];

        // interactions
        // collect payment from buyer
        if (L.paymentToken == address(0)) {
            require(msg.value == price, "bad msg.value");
            // 1. royalty
            if (royaltyAmount > 0 && royaltyRecipient != address(0)) {
                (bool ok1, ) = payable(royaltyRecipient).call{value: royaltyAmount}("");
                if (!ok1) revert TransferFailed();
            }
            // 2. staking fee -> pool.notifyFee(native)
            address pool = address(0);
            if (factory != address(0)) { pool = ICollectionFactory(factory).getPool(nft); }
            if (pool == address(0)) { pool = stakingPool; } // legacy fallback
            if (pool != address(0) && stakingFee > 0) {
                (bool ok2, ) = pool.call{value: stakingFee}(abi.encodeWithSignature("notifyFee(address,uint256)", address(0), stakingFee));
                if (!ok2) revert TransferFailed();
            }
            // 3. platform fee -> treasury
            (bool ok3, ) = payable(treasury).call{value: platformFee}("");
            if (!ok3) revert TransferFailed();
            // 4. seller
            (bool ok4, ) = payable(seller).call{value: sellerProceeds}("");
            if (!ok4) revert TransferFailed();
        } else {
            IERC20 token = IERC20(L.paymentToken);
            require(token.transferFrom(msg.sender, address(this), price), "pay erc20 failed");
            // 1. royalty
            if (royaltyAmount > 0 && royaltyRecipient != address(0)) {
                require(token.transfer(royaltyRecipient, royaltyAmount), "royalty erc20 failed");
            }
            // 2. staking fee -> pool.notifyFee(token)
            address pool = address(0);
            if (factory != address(0)) { pool = ICollectionFactory(factory).getPool(nft); }
            if (pool == address(0)) { pool = stakingPool; } // legacy fallback
            if (pool != address(0) && stakingFee > 0) {
                require(token.transfer(pool, stakingFee), "pool erc20 xfer failed");
                (bool ok2, ) = pool.call(abi.encodeWithSignature("notifyFee(address,uint256)", address(token), stakingFee));
                if (!ok2) revert TransferFailed();
            }
            // 3. platform fee
            require(token.transfer(treasury, platformFee), "platform erc20 failed");
            // 4. seller
            require(token.transfer(seller, sellerProceeds), "seller erc20 failed");
        }

        // transfer NFT to buyer
        IERC721(nft).safeTransferFrom(seller, msg.sender, tokenId);

        emit Bought(nft, tokenId, msg.sender, seller, price, L.paymentToken, royaltyAmount, stakingFee, platformFee);
    }

    function _royalty(address nft, uint256 tokenId, uint256 price) internal view returns (uint256 amount, address receiver) {
        // If collection supports ERC2981, query it; else 0
        try IERC2981(nft).royaltyInfo(tokenId, price) returns (address rec, uint256 amt) {
            // cap royalty at royaltyCapBP
            uint256 cap = (price * uint256(royaltyCapBP)) / BPS_DENOM;
            amount = amt > cap ? cap : amt;
            receiver = rec;
        } catch {
            amount = 0;
            receiver = address(0);
        }
    }
}
