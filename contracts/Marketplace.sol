
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

interface IFactory {
    function getPool(address collection) external view returns (address);
}

interface IStakingPool {
    function isStaked(uint256 tokenId) external view returns (bool);
    function notifyFee(uint256 amount) external payable;
}

contract Marketplace is Ownable, Pausable, ReentrancyGuard {
    struct Listing {
        address seller;
        uint256 price;
        address paymentToken;
        bool active;
    }

    uint256 public platformFeeBP;
    uint256 public stakingFeeBP;
    uint256 public royaltyCapBP;

    address public treasury;
    IFactory public factory;

    mapping(address => mapping(uint256 => Listing)) public listings;
    mapping(address => bool) public allowedPaymentToken;

    event Listed(address indexed nft, uint256 indexed tokenId, address indexed seller, uint256 price, address paymentToken);
    event Cancelled(address indexed nft, uint256 indexed tokenId, address indexed seller);
    event Bought(
        address indexed nft, uint256 indexed tokenId, address indexed buyer,
        address seller, uint256 price, address paymentToken,
        uint256 royaltyAmount, uint256 stakingFee, uint256 platformFee
    );

    constructor(
        address owner_,
        address treasury_,
        uint256 platformFeeBP_,
        uint256 stakingFeeBP_,
        uint256 royaltyCapBP_
    ) Ownable(owner_) {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        platformFeeBP = platformFeeBP_;
        stakingFeeBP = stakingFeeBP_;
        royaltyCapBP = royaltyCapBP_;
        allowedPaymentToken[address(0)] = true;
    }

    function setFactory(address _factory) external onlyOwner {
        factory = IFactory(_factory);
    }
    function setPaymentToken(address token, bool allowed) external onlyOwner {
        allowedPaymentToken[token] = allowed;
    }
    function setFees(uint256 platformBP, uint256 stakingBP, uint256 royaltyCapBP_) external onlyOwner {
        require(platformBP <= 10_000 && stakingBP <= 10_000 && royaltyCapBP_ <= 10_000, "bp>100%");
        platformFeeBP = platformBP;
        stakingFeeBP = stakingBP;
        royaltyCapBP = royaltyCapBP_;
    }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function list(address nft, uint256 tokenId, uint256 price, address paymentToken) external whenNotPaused nonReentrant {
        require(price > 0, "price=0");
        require(allowedPaymentToken[paymentToken], "payment not allowed");
        IERC721 c = IERC721(nft);
        require(c.ownerOf(tokenId) == msg.sender, "not owner");
        require(c.isApprovedForAll(msg.sender, address(this)), "approve marketplace");

        address pool = address(0);
        if (address(factory) != address(0)) {
            pool = factory.getPool(nft);
            if (pool != address(0)) {
                require(!IStakingPool(pool).isStaked(tokenId), "staked");
            }
        }

        listings[nft][tokenId] = Listing({ seller: msg.sender, price, paymentToken, active: true });
        emit Listed(nft, tokenId, msg.sender, price, paymentToken);
    }

    function cancel(address nft, uint256 tokenId) external nonReentrant {
        Listing memory L = listings[nft][tokenId];
        require(L.active, "not listed");
        require(L.seller == msg.sender, "not seller");
        delete listings[nft][tokenId];
        emit Cancelled(nft, tokenId, msg.sender);
    }

    function buy(address nft, uint256 tokenId) external payable whenNotPaused nonReentrant {
        Listing memory L = listings[nft][tokenId];
        require(L.active, "not listed");
        require(L.paymentToken == address(0), "only KAS");
        require(msg.value == L.price, "wrong value");

        delete listings[nft][tokenId];

        (address royaltyRecv, uint256 royaltyAmtRaw) = _royalty(nft, tokenId, L.price);
        uint256 royaltyAmt = royaltyAmtRaw;
        uint256 capAmt = (L.price * royaltyCapBP) / 10_000;
        if (royaltyAmt > capAmt) royaltyAmt = capAmt;

        uint256 stakingFee = (L.price * stakingFeeBP) / 10_000;
        uint256 platformFee = (L.price * platformFeeBP) / 10_000;
        uint256 proceeds = L.price - royaltyAmt - stakingFee - platformFee;

        address pool = address(0);
        if (address(factory) != address(0)) {
            pool = factory.getPool(nft);
        }
        if (pool != address(0) && stakingFee > 0) {
            (bool okPool, ) = payable(pool).call{value: stakingFee}(abi.encodeWithSelector(IStakingPool.notifyFee.selector, stakingFee));
            require(okPool, "pool fee fail");
        } else if (stakingFee > 0) {
            (bool okAlt, ) = payable(treasury).call{value: stakingFee}("");
            require(okAlt, "stake fee xfer fail");
        }

        if (royaltyAmt > 0 && royaltyRecv != address(0)) {
            (bool okR, ) = payable(royaltyRecv).call{value: royaltyAmt}("");
            require(okR, "royalty xfer fail");
        }
        if (platformFee > 0) {
            (bool okP, ) = payable(treasury).call{value: platformFee}("");
            require(okP, "platform xfer fail");
        }

        IERC721(nft).safeTransferFrom(L.seller, msg.sender, tokenId);
        (bool okS, ) = payable(L.seller).call{value: proceeds}("");
        require(okS, "seller xfer fail");

        emit Bought(nft, tokenId, msg.sender, L.seller, L.price, L.paymentToken, royaltyAmt, stakingFee, platformFee);
    }

    function _royalty(address nft, uint256 tokenId, uint256 price) internal view returns (address, uint256) {
        try IERC2981(nft).royaltyInfo(tokenId, price) returns (address recv, uint256 amt) {
            return (recv, amt);
        } catch {
            return (address(0), 0);
        }
    }

    receive() external payable {}
}
