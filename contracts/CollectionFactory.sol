// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NFTCollection} from "./NFTCollection.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CollectionFactory
 * @dev Deploys new NFTCollection contracts with a default royalty.
 */
contract CollectionFactory is Ownable {
    event CollectionDeployed(address indexed collection, address indexed owner, string name, string symbol, address royaltyReceiver, uint96 royaltyBps);

    constructor(address owner_) Ownable(owner_) {}

    function deployCollection(
        string calldata name_,
        string calldata symbol_,
        address royaltyReceiver,
        uint96 royaltyBps
    ) external onlyOwner returns (address addr) {
        NFTCollection c = new NFTCollection(name_, symbol_, royaltyReceiver, royaltyBps);
        c.transferOwnership(msg.sender);
        addr = address(c);
        emit CollectionDeployed(addr, msg.sender, name_, symbol_, royaltyReceiver, royaltyBps);
    }
}
