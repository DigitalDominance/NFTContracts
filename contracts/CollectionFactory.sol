import "./StakingPool.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NFTCollection} from "./NFTCollection.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CollectionFactory
 * @dev Deploys new NFTCollection contracts with configurable mint params.
 * - Charges a flat **5 KAS** deploy fee that is forwarded to `treasury`.
 */
contract CollectionFactory is Ownable {
    mapping(address => address) public stakingPoolOf;

    function getPool(address collection) public view returns (address) { return stakingPoolOf[collection]; }

    event CollectionDeployed(
        address indexed collection,
        address indexed owner, address indexed stakingPool,
        string  name,
        string  symbol,
        address royaltyReceiver,
        uint96  royaltyBps,
        uint256 mintPrice,
        uint256 maxPerWallet,
        uint256 maxSupply,
        string  baseURI
    );

    address public immutable treasury;
    uint256 public constant DEPLOY_FEE = 5 ether; // 5 KAS (18 decimals)

    constructor(address owner_, address treasury_) Ownable(owner_) {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
    }

    /**
     * @notice Deploy a new NFTCollection.
     * @param name_           Collection name
     * @param symbol_         Collection symbol
     * @param royaltyReceiver Default ERC-2981 royalty receiver
     * @param royaltyBps      Default royalty (basis points)
     * @param mintPrice       Public mint price (wei)
     * @param maxPerWallet    Max mintable per wallet
     * @param maxSupply       Total supply cap (e.g., number of images)
     * @param baseURI         Base URI prefix (e.g., https://.../ or ipfs://.../)
     */
    function deployCollection(
        string calldata name_,
        string calldata symbol_,
        address royaltyReceiver,
        uint96  royaltyBps,
        uint256 mintPrice,
        uint256 maxPerWallet,
        uint256 maxSupply,
        string calldata baseURI
    ) external payable onlyOwner returns (address addr) {
        require(msg.value == DEPLOY_FEE, "fee=5 KAS");
        address _pool = address(new StakingPool(addr));
        stakingPoolOf[addr] = _pool;
        // forward fee to treasury
        (bool ok, ) = payable(treasury).call{value: msg.value}("");
        require(ok, "fee xfer failed");

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

        // Factory owner remains collection owner by default; transfer to sender (factory owner)
        c.transferOwnership(msg.sender);
        addr = address(c);

        emit CollectionDeployed(
            addr,
            msg.sender,
            name_,
            symbol_,
            royaltyReceiver,
            royaltyBps,
            mintPrice,
            maxPerWallet,
            maxSupply,
            baseURI
        );
    }
}
