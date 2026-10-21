// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BloomFactory} from "../src/BloomFactory.sol";
import {BloomTreasury} from "../src/BloomTreasury.sol";
import {DeploymentInputs} from "./DeploymentInputs.sol";

/// @notice Local deployment rehearsal. The deployment service uses the application initcode directly.
/// @dev There is deliberately no startBroadcast: even --broadcast cannot send transactions from this script.
contract DeployCore {
    function run() external returns (BloomTreasury treasury, BloomFactory registry) {
        DeploymentInputs.checkChain();
        treasury = new BloomTreasury(DeploymentInputs.REQUESTER);
        registry = new BloomFactory(DeploymentInputs.REQUESTER, address(treasury));
    }
}
