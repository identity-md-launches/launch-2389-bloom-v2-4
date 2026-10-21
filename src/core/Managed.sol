// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Every authority starts with the explicit requester, never the constructor caller.
abstract contract Managed is Ownable2Step {
    uint256 public constant CONFIG = 1;
    uint256 public constant REWARDS = 2;
    uint256 public constant PAUSE = 4;
    uint256 public constant RECOVERY = 8;
    uint256 public constant SPEND = 16;
    uint256 public renouncedPowers;

    error PowerRenounced(uint256 power);
    error InvalidPower();
    event PowersRenounced(address indexed owner, uint256 powers);

    constructor(address owner_) Ownable(owner_) {}

    modifier withPower(uint256 power) {
        _checkOwner();
        if (renouncedPowers & power != 0) revert PowerRenounced(power);
        _;
    }

    /// @notice Irreversible, selective removal of powers. Never invoked automatically.
    function renouncePowers(uint256 powers) external onlyOwner {
        if (powers == 0 || powers & ~uint256(31) != 0) revert InvalidPower();
        renouncedPowers |= powers;
        emit PowersRenounced(msg.sender, powers);
    }
}
