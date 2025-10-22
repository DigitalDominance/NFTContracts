// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title StakingPool (collection-specific)
 * @notice 1 staked NFT = 1 share. Rewards are distributed per-share via accPerShare.
 *         This pool is bound to a single ERC721 collection (COLLECTION).
 *         Native KAS rewards use currency = address(0).
 */
contract StakingPool is IERC721Receiver, ReentrancyGuard {
    address public immutable COLLECTION;

    // --- shares ---
    uint256 public totalShares;
    mapping(address => uint256) public balanceOf; // shares per user
    mapping(uint256 => address) public stakerOf;  // tokenId => original owner
    mapping(uint256 => bool) public isStaked;     // tokenId staked flag

    // --- rewards ---
    struct RewardState { uint256 accPerShare; } // scaled by 1e18
    mapping(address => RewardState) public rewardState;           // currency => state
    mapping(address => mapping(address => uint256)) public rewardDebt; // user => currency => debt
    mapping(address => uint256) public feeBuffer;                 // currency => buffered when totalShares==0

    uint256 private constant ACC = 1e18;

    event Staked(address indexed user, uint256 indexed tokenId);
    event Unstaked(address indexed user, uint256 indexed tokenId);
    event Claimed(address indexed user, address indexed currency, uint256 amount);
    event FeeNotified(address indexed currency, uint256 amount, uint256 accPerShare);
    event BufferFlushed(address indexed currency, uint256 amount, uint256 accPerShareAfter);

    constructor(address collection_) {
        require(collection_ != address(0), "collection=0");
        COLLECTION = collection_;
    }

    // ---- views ----
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function pending(address user, address currency) public view returns (uint256) {
        uint256 shares = balanceOf[user];
        if (shares == 0) return 0;
        uint256 acc = rewardState[currency].accPerShare;
        // NOTE: feeBuffer is not auto-included to keep view pure; call flushBuffer for exactness
        uint256 debt = rewardDebt[user][currency];
        uint256 gross = (shares * acc) / ACC;
        return gross > debt ? gross - debt : 0;
    }

    // ---- internal helpers ----
    function _settle(address user, address currency) internal returns (uint256 claimed) {
        uint256 p = pending(user, currency);
        if (p > 0) {
            rewardDebt[user][currency] += p;
            if (currency == address(0)) {
                (bool ok, ) = payable(user).call{value: p}("");
                require(ok, "native xfer failed");
            } else {
                // ERC20 path (optional extension): assume tokens were transferred to this pool
                (bool ok, bytes memory data) = currency.call(abi.encodeWithSignature("transfer(address,uint256)", user, p));
                require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 xfer failed");
            }
            emit Claimed(user, currency, p);
            return p;
        }
        return 0;
    }

    function _updateDebt(address user) internal {
        // sync user debt across the one default currency (native) for now
        address currency = address(0);
        uint256 shares = balanceOf[user];
        rewardDebt[user][currency] = (shares * rewardState[currency].accPerShare) / ACC;
    }

    // ---- user actions ----
    function stake(uint256 tokenId) external nonReentrant {
        require(!isStaked[tokenId], "already staked");
        // settle current rewards for user before increasing shares
        _settle(msg.sender, address(0));

        // pull NFT
        IERC721(COLLECTION).safeTransferFrom(msg.sender, address(this), tokenId);
        isStaked[tokenId] = true;
        stakerOf[tokenId] = msg.sender;

        // increment shares
        balanceOf[msg.sender] += 1;
        totalShares += 1;

        // update reward debt
        _updateDebt(msg.sender);

        emit Staked(msg.sender, tokenId);
    }

    function unstake(uint256 tokenId) external nonReentrant {
        require(isStaked[tokenId], "not staked");
        address owner_ = stakerOf[tokenId];
        require(owner_ == msg.sender, "not staker");

        // claim all native before reducing shares
        _settle(msg.sender, address(0));

        // reduce shares
        balanceOf[msg.sender] -= 1;
        totalShares -= 1;

        // return NFT
        isStaked[tokenId] = false;
        stakerOf[tokenId] = address(0);
        IERC721(COLLECTION).safeTransferFrom(address(this), msg.sender, tokenId);

        // update reward debt
        _updateDebt(msg.sender);

        emit Unstaked(msg.sender, tokenId);
    }

    function claimAll() external nonReentrant {
        _settle(msg.sender, address(0));
        _updateDebt(msg.sender);
    }

    // ---- fee notify ----
    function notifyFee(address currency, uint256 amount) external payable nonReentrant {
        if (currency == address(0)) {
            require(msg.value == amount, "bad msg.value");
        } else {
            // For ERC20 fees, the caller should transfer tokens to this contract before calling notifyFee,
            // or you can extend with permit/pull pattern.
        }

        if (totalShares == 0) {
            feeBuffer[currency] += amount;
            emit FeeNotified(currency, amount, rewardState[currency].accPerShare);
            return;
        }

        // distribute immediately
        RewardState storage rs = rewardState[currency];
        rs.accPerShare += (amount * ACC) / totalShares;
        emit FeeNotified(currency, amount, rs.accPerShare);
    }

    function flushBuffer(address currency) external nonReentrant {
        uint256 buf = feeBuffer[currency];
        if (buf == 0) return;
        feeBuffer[currency] = 0;
        if (totalShares == 0) {
            // re-buffer if still no stakers
            feeBuffer[currency] = buf;
            return;
        }
        RewardState storage rs = rewardState[currency];
        rs.accPerShare += (buf * ACC) / totalShares;
        emit BufferFlushed(currency, buf, rs.accPerShare);
    }

    // receive native
    receive() external payable {}
}
