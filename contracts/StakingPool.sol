// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721, IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICollectionLike is IERC721 {}

/// @title StakingPool (per-collection)
/// @notice 1 NFT = 1 share. KAS rewards are distributed pro‑rata by shares.
contract StakingPool is ReentrancyGuard, IERC721Receiver {
    address public immutable COLLECTION;

    // --- Share-based accounting ---
    uint256 public totalShares;
    mapping(address => uint256) public balanceOf;     // user -> shares (# of NFTs staked)
    mapping(uint256 => address) public stakedBy;      // tokenId -> staker

    // reward accumulator (scaled by 1e18)
    uint256 public accPerShare;
    mapping(address => uint256) public rewardDebt;    // user -> accumulated amount already accounted

    // handle fees arriving when there are no stakers
    uint256 public unallocatedRewards;

    event Staked(address indexed user, uint256 indexed tokenId);
    event Unstaked(address indexed user, uint256 indexed tokenId);
    event Claimed(address indexed user, uint256 amount);
    event FeeNotified(uint256 amount, uint256 accPerShare);

    constructor(address collection_) {
        require(collection_ != address(0), "collection=0");
        COLLECTION = collection_;
    }

    // --- IERC721Receiver ---
    function onERC721Received(
        address /*operator*/,
        address /*from*/,
        uint256 /*tokenId*/,
        bytes calldata /*data*/
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // --- Views ---

    function isStaked(uint256 tokenId) external view returns (bool) {
        return stakedBy[tokenId] != address(0);
    }

    function pending(address user) public view returns (uint256) {
        uint256 shares = balanceOf[user];
        uint256 entitled = (shares * accPerShare) / 1e18;
        uint256 debt = rewardDebt[user];
        if (entitled <= debt) return 0;
        return entitled - debt;
    }

    // --- Actions ---

    function stake(uint256 tokenId) external nonReentrant {
        // prechecks
        require(stakedBy[tokenId] == address(0), "already staked");
        require(ICollectionLike(COLLECTION).ownerOf(tokenId) == msg.sender, "not owner");
        // accrue before changing shares
        _accrue(msg.sender);

        // pull the NFT into custody (requires prior setApprovalForAll)
        ICollectionLike(COLLECTION).safeTransferFrom(msg.sender, address(this), tokenId);

        // effects
        stakedBy[tokenId] = msg.sender;
        unchecked { totalShares += 1; }
        unchecked { balanceOf[msg.sender] += 1; }

        // sync reward debt to new share count
        rewardDebt[msg.sender] = (balanceOf[msg.sender] * accPerShare) / 1e18;

        emit Staked(msg.sender, tokenId);
    }

    function unstake(uint256 tokenId) external nonReentrant {
        address owner = stakedBy[tokenId];
        require(owner == msg.sender, "not staker");

        // accrue before changing shares
        _accrue(msg.sender);

        // effects
        stakedBy[tokenId] = address(0);
        unchecked { totalShares -= 1; }
        unchecked { balanceOf[msg.sender] -= 1; }

        // sync reward debt to new share count
        rewardDebt[msg.sender] = (balanceOf[msg.sender] * accPerShare) / 1e18;

        // transfer out
        ICollectionLike(COLLECTION).safeTransferFrom(address(this), msg.sender, tokenId);

        emit Unstaked(msg.sender, tokenId);
    }

    function claimAll() external nonReentrant {
        uint256 amt = pending(msg.sender);
        require(amt > 0, "nothing to claim");
        // effects
        rewardDebt[msg.sender] += amt; // or set to shares*accPerShare; additive is fine with our pending() def
        // interactions
        (bool ok, ) = payable(msg.sender).call{value: amt}("");
        require(ok, "claim xfer fail");
        emit Claimed(msg.sender, amt);
    }

    /// @notice Called by marketplace on each sale to push KAS staking fee here.
    function notifyFee(uint256 amount) external payable nonReentrant {
        require(msg.value == amount, "value!=amount");
        uint256 total = amount + unallocatedRewards;

        if (totalShares == 0) {
            // hold until someone stakes
            unallocatedRewards = total;
        } else {
            unallocatedRewards = 0;
            accPerShare += (total * 1e18) / totalShares;
        }
        emit FeeNotified(amount, accPerShare);
    }

    // --- Internal ---
    function _accrue(address user) internal {
        uint256 shares = balanceOf[user];
        uint256 entitled = (shares * accPerShare) / 1e18;
        uint256 debt = rewardDebt[user];
        if (entitled > debt) {
            rewardDebt[user] = entitled;
        }
    }

    receive() external payable {}
}
