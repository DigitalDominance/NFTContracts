// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StakingPool (Upgradeable)
 * @dev Stake ERC721 tokens. Rewards distributed from marketplace fees via notifyFee (native or ERC20).
 * Reward model: 1 share per staked NFT, accRewardPerShare scaled by 1e18. Per currency accounting.
 */
contract StakingPool is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    // marketplace that is allowed to notify fees
    address public marketplace;

    // total shares = count of staked NFTs
    uint256 public totalShares;

    // staked[nft][tokenId] => staker
    mapping(address => mapping(uint256 => address)) public stakedBy;

    // user balances (number of NFTs staked)
    mapping(address => uint256) public balanceOf;

    // reward accounting per currency (address(0) = native)
    struct RewardState {
        uint256 accPerShare; // scaled by 1e18
    }
    mapping(address => RewardState) public rewardState; // currency => state

    // user reward debt per currency
    mapping(address => mapping(address => uint256)) public rewardDebt; // user => currency => debt

    // pending buffer for currencies if no stakers yet
    mapping(address => uint256) public feeBuffer; // currency => amount

    event Staked(address indexed user, address indexed nft, uint256 indexed tokenId);
    event Unstaked(address indexed user, address indexed nft, uint256 indexed tokenId);
    event Claimed(address indexed user, address indexed currency, uint256 amount);
    event FeeNotified(address indexed currency, uint256 amount, uint256 accPerShare);
    event MarketplaceUpdated(address indexed oldM, address indexed newM);

    modifier onlyMarketplace() {
        require(msg.sender == marketplace, "not marketplace");
        _;
    }

    function initialize(address owner_) public initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setMarketplace(address m) external onlyOwner {
        emit MarketplaceUpdated(marketplace, m);
        marketplace = m;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function isStaked(address nft, uint256 tokenId) public view returns (bool) {
        return stakedBy[nft][tokenId] != address(0);
    }

    function stake(address nft, uint256 tokenId) external whenNotPaused nonReentrant {
        IERC721(nft).transferFrom(msg.sender, address(this), tokenId);
        require(stakedBy[nft][tokenId] == address(0), "already staked");
        stakedBy[nft][tokenId] = msg.sender;
        balanceOf[msg.sender] += 1;
        totalShares += 1;
        _updateRewardsOnChange(msg.sender);
        emit Staked(msg.sender, nft, tokenId);
    }

    function unstake(address nft, uint256 tokenId) external whenNotPaused nonReentrant {
        require(stakedBy[nft][tokenId] == msg.sender, "not staker");
        _claimAll(msg.sender);
        stakedBy[nft][tokenId] = address(0);
        balanceOf[msg.sender] -= 1;
        totalShares -= 1;
        IERC721(nft).transferFrom(address(this), msg.sender, tokenId);
        _updateRewardsOnChange(msg.sender);
        emit Unstaked(msg.sender, nft, tokenId);
    }

    // Marketplace notifies fees; currency = address(0) for native or ERC20 token address
    function notifyFee(address currency, uint256 amount) external payable onlyMarketplace nonReentrant {
        if (currency == address(0)) {
            require(msg.value == amount, "native amount mismatch");
        } else {
            require(msg.value == 0, "no native");
            require(IERC20(currency).transferFrom(msg.sender, address(this), amount), "fee xfer fail");
        }

        if (totalShares == 0) {
            // buffer until someone stakes
            if (currency == address(0)) {
                feeBuffer[address(0)] += amount;
            } else {
                feeBuffer[currency] += amount;
            }
            emit FeeNotified(currency, amount, rewardState[currency].accPerShare);
            return;
        }

        uint256 scaled = (amount * 1e18) / totalShares;
        rewardState[currency].accPerShare += scaled;
        emit FeeNotified(currency, amount, rewardState[currency].accPerShare);
    }

    function claimAll() external nonReentrant {
        _claimAll(msg.sender);
    }

    function _claimAll(address user) internal {
        // claim native
        _claim(user, address(0));
        // NOTE: If you allow ERC20 currencies, you may loop a known list managed by owner.
        // For simplicity, only native is claimed here; extend with allowlist if needed.
    }

    function _claim(address user, address currency) internal {
        uint256 pending = _pending(user, currency);
        if (pending > 0) {
            if (currency == address(0)) {
                (bool ok, ) = payable(user).call{value: pending}("");
                require(ok, "claim native failed");
            } else {
                require(IERC20(currency).transfer(user, pending), "claim erc20 failed");
            }
            rewardDebt[user][currency] = rewardState[currency].accPerShare * balanceOf[user] / 1e18;
            emit Claimed(user, currency, pending);
        } else {
            rewardDebt[user][currency] = rewardState[currency].accPerShare * balanceOf[user] / 1e18;
        }
    }

    function _pending(address user, address currency) internal view returns (uint256) {
        uint256 acc = rewardState[currency].accPerShare;
        uint256 shares = balanceOf[user];
        uint256 debt = rewardDebt[user][currency];
        if (shares == 0) return 0;
        return (acc * shares / 1e18) - debt;
    }

    function _updateRewardsOnChange(address user) internal {
        // reset rewardDebt to current accPerShare
        rewardDebt[user][address(0)] = rewardState[address(0)].accPerShare * balanceOf[user] / 1e18;
    }

    // Helper to distribute buffered fees when first stake happens
    function flushBuffer(address currency) external nonReentrant {
        uint256 amount = feeBuffer[currency];
        require(amount > 0, "no buffer");
        require(totalShares > 0, "no shares");
        feeBuffer[currency] = 0;
        uint256 scaled = (amount * 1e18) / totalShares;
        rewardState[currency].accPerShare += scaled;
        emit FeeNotified(currency, amount, rewardState[currency].accPerShare);
    }
}
