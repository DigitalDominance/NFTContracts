
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {NFTCollection} from "./NFTCollection.sol";
import {StakingPool} from "./StakingPool.sol";

contract CollectionFactory is Ownable {
    uint256 public constant DEPLOY_FEE = 5 ether; // 5 KAS (18 decimals)
    address public treasury;

    // collection => pool
    mapping(address => address) public stakingPoolOf;

    event CollectionDeployed(
        address indexed collection,
        address indexed owner,
        address indexed stakingPool,
        string name,
        string symbol,
        address royaltyReceiver,
        uint96 royaltyBps,
        uint256 mintPrice,
        uint256 maxPerWallet,
        uint256 maxSupply,
        string baseURI
    );

    constructor(address owner_, address treasury_) Ownable(owner_) {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "t=0");
        treasury = t;
    }

    function getPool(address collection) external view returns (address) {
        return stakingPoolOf[collection];
    }

    function deployCollection(
        string calldata name_,
        string calldata symbol_,
        string calldata baseURI,
        address royaltyReceiver,
        uint96  royaltyBps,
        uint256 mintPrice,
        uint256 maxPerWallet,
        uint256 maxSupply
    ) external payable returns (address addr) {
        require(msg.value == DEPLOY_FEE, "fee=5 KAS");
        require(bytes(name_).length > 0 && bytes(symbol_).length > 0, "name/symbol empty");
        require(maxSupply > 0, "maxSupply=0");
        require(royaltyBps <= 10_000, "royalty>100%");

        // 1) Deploy collection
        NFTCollection c = new NFTCollection(
            name_,
            symbol_,
            royaltyReceiver,
            royaltyBps,
            mintPrice,
            maxPerWallet,
            maxSupply,
            baseURI
        );

        // 2) Transfer ownership to deployer
        c.transferOwnership(msg.sender);
        addr = address(c);

        // 3) Deploy per-collection staking pool (non-upgradeable)
        address pool = address(new StakingPool(addr));
        stakingPoolOf[addr] = pool;

        // 4) Forward the fixed fee to treasury
        (bool ok, ) = payable(treasury).call{value: msg.value}("");
        require(ok, "fee xfer failed");

        // 5) Emit event
        emit CollectionDeployed(
            addr,
            msg.sender,
            pool,
            name_,
            symbol_,
            royaltyReceiver,
            royaltyBps,
            mintPrice,
            maxPerWallet,
            maxSupply,
            baseURI
        );

        return addr;
    }
}
