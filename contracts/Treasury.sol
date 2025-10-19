// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Treasury
 * @dev Minimal treasury that can receive native fees and sweep by owner (multisig).
 */
contract Treasury is Ownable {
    constructor(address owner_) Ownable(owner_) {}

    receive() external payable {}

    function sweep(address payable to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "sweep failed");
    }
}
