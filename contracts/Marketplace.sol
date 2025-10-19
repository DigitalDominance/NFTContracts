// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

/**
 * @title Marketplace (Upgradeable, UUPS)
 * @dev Listing & purchase of ERC721. Fees: 0.7% total (70 bp) split: royalty 20bp (capped), staking 30bp, platform 20bp.
 * Supports native payments (address(0)) and allow-listed ERC20 tokens.
 */
contract Marketplace is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant BPS_DENOM = 10_000;

    struct Listing {
        address seller;
        uint256 price;         // in payment currency's smallest unit
        address paymentToken;  // address(0) for native, else ERC20 token
        bool active;
    }

    // fees in bp
    uint96 public platformFeeBP;   // default 20
    uint96 public stakingFeeBP;    // default 30
    uint96 public royaltyCapBP;    // default 20

    address public treasury;       // platform treasury (multisig or Treasury contract address)
    address public stakingPool;    // staking pool contract address

    // approvals for ERC20 payments
    mapping(address => bool) public approvedPaymentToken;

    // listings[nft][tokenId]
    mapping(address => mapping(uint256 => Listing)) public listings;

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

    error NotOwner();
    error InvalidPrice();
    error NotListed();
    error AlreadyListed();
    error PaymentTokenNotAllowed();
    error TransferFailed();

    function initialize(
        address owner_,
        address treasury_,
        address stakingPool_,
        uint96 platformFeeBP_,
        uint96 stakingFeeBP_,
        uint96 royaltyCapBP_
    ) public initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        treasury = treasury_;
        stakingPool = stakingPool_;
        platformFeeBP = platformFeeBP_;
        stakingFeeBP = stakingFeeBP_;
        royaltyCapBP = royaltyCapBP_;
        approvedPaymentToken[address(0)] = true; // native KAS enabled by default
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setTreasury(address t) external onlyOwner { treasury = t; }
    function setStakingPool(address s) external onlyOwner { stakingPool = s; }
    function setFees(uint96 platformBP, uint96 stakingBP, uint96 royaltyCapBP_) external onlyOwner {
        require(platformBP + stakingBP <= 70, "sum too high");
        platformFeeBP = platformBP;
        stakingFeeBP = stakingBP;
        royaltyCapBP = royaltyCapBP_;
    }

    function setPaymentToken(address token, bool allowed) external onlyOwner {
        approvedPaymentToken[token] = allowed;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // Prevent listing of staked NFTs: stakingPool exposes isStaked(nft, tokenId)
    function _ensureNotStaked(address nft, uint256 tokenId) internal view {
        (bool ok, bytes memory data) = stakingPool.staticcall(abi.encodeWithSignature("isStaked(address,uint256)", nft, tokenId));
        require(ok && data.length == 32, "stake check failed");
        bool isStkd = abi.decode(data, (bool));
        require(!isStkd, "token is staked");
    }

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
        // marketplace needs approval on the NFT transfer
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
        uint256 stakingFee = (price * stakingFeeBP) / BPS_DENOM;
        uint256 platformFee = (price * platformFeeBP) / BPS_DENOM;
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
            // 2. staking fee -> stakingPool.notifyFee(native)
            (bool ok2, ) = stakingPool.call{value: stakingFee}(abi.encodeWithSignature("notifyFee(address,uint256)", address(0), stakingFee));
            if (!ok2) revert TransferFailed();
            // 3. platform fee -> treasury
            (bool ok3, ) = payable(treasury).call{value: platformFee}("");
            if (!ok3) revert TransferFailed();
            // 4. seller proceeds
            (bool ok4, ) = payable(seller).call{value: sellerProceeds}("");
            if (!ok4) revert TransferFailed();
        } else {
            // ERC20 path
            require(approvedPaymentToken[L.paymentToken], "token not allowed");
            IERC20 token = IERC20(L.paymentToken);
            require(token.transferFrom(msg.sender, address(this), price), "pay in erc20 failed");
            if (royaltyAmount > 0 && royaltyRecipient != address(0)) {
                require(token.transfer(royaltyRecipient, royaltyAmount), "royalty erc20 failed");
            }
            // staking fee delivered to staking pool
            require(token.approve(stakingPool, stakingFee), "approve fail");
            (bool ok2, ) = stakingPool.call(abi.encodeWithSignature("notifyFee(address,uint256)", L.paymentToken, stakingFee));
            require(ok2, "notify fail");
            // platform fee
            require(token.transfer(treasury, platformFee), "platform erc20 failed");
            // seller
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
            uint256 cap = (price * royaltyCapBP) / BPS_DENOM;
            amount = amt > cap ? cap : amt;
            receiver = rec;
        } catch {
            amount = 0;
            receiver = address(0);
        }
    }
}
