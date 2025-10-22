
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICollectionLike is IERC721 {}

contract StakingPool is ReentrancyGuard {
    address public immutable COLLECTION;

    // share-based accounting (1 share per staked NFT)
    uint256 public totalShares;
    mapping(address => uint256) public balanceOf; // user shares
    mapping(uint256 => address) public stakedBy;  // tokenId -> staker

    // rewards (native KAS at address(0))
    uint256 public accPerShare; // scaled by 1e18
    mapping(address => uint256) public rewardDebt; // user -> debt in KAS

    event Staked(address indexed user, uint256 indexed tokenId);
    event Unstaked(address indexed user, uint256 indexed tokenId);
    event Claimed(address indexed user, uint256 amount);
    event FeeNotified(uint256 amount, uint256 accPerShare);

    constructor(address collection_) {
        require(collection_ != address(0), "collection=0");
        COLLECTION = collection_;
    }

    // --- Views ---
    function isStaked(uint256 tokenId) external view returns (bool) {
        return stakedBy[tokenId] != address(0);
    }

    function pending(address user) public view returns (uint256) {
        uint256 shares = balanceOf[user];
        uint256 entitled = (shares * accPerShare) / 1e18;
        uint256 debt = rewardDebt[user];
        if (entitled < debt) return 0;
        return entitled - debt;
    }

    // --- Actions ---
    function stake(uint256 tokenId) external nonReentrant {
        ICollectionLike(COLLECTION).safeTransferFrom(msg.sender, address(this), tokenId);
        require(stakedBy[tokenId] == address(0), "already staked");
        _accrue(msg.sender);

        stakedBy[tokenId] = msg.sender;
        balanceOf[msg.sender] += 1;
        totalShares += 1;

        emit Staked(msg.sender, tokenId);
    }

    function unstake(uint256 tokenId) external nonReentrant {
        require(stakedBy[tokenId] == msg.sender, "not staker");
        _accrue(msg.sender);

        stakedBy[tokenId] = address(0);
        balanceOf[msg.sender] -= 1;
        totalShares -= 1;

        ICollectionLike(COLLECTION).safeTransferFrom(address(this), msg.sender, tokenId);
        emit Unstaked(msg.sender, tokenId);
    }

    function claimAll() external nonReentrant {
        _accrue(msg.sender);
        uint256 amount = pending(msg.sender);
        if (amount > 0) {
            rewardDebt[msg.sender] += amount;
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            require(ok, "claim fail");
            emit Claimed(msg.sender, amount);
        }
    }

    function notifyFee(uint256 amount) external payable nonReentrant {
        require(msg.value == amount, "value!=amount");
        if (totalShares == 0) {
            return;
        }
        accPerShare += (amount * 1e18) / totalShares;
        emit FeeNotified(amount, accPerShare);
    }

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
