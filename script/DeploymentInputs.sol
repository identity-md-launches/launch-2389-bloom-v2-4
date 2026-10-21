// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBloomRegistry} from "../src/interfaces/IBloom.sol";
import {BloomTreasury} from "../src/BloomTreasury.sol";

/// @dev Simulation helpers only: no signing, environment reads or broadcast cheatcodes.
library DeploymentInputs {
    address internal constant REQUESTER = 0xDEA11b3A70b77134424d436f6eb455f1Abbd4449;

    function checkChain() internal view {
        require(block.chainid == 1, "Ethereum mainnet only");
    }

    function checkFarm(address registry, address treasury, address bloom) internal view {
        checkChain();
        require(
            registry.code.length != 0 && treasury.code.length != 0 && bloom.code.length != 0,
            "Real deployed dependencies required"
        );
        require(IBloomRegistry(registry).owner() == REQUESTER, "Requester must own registry");
        require(BloomTreasury(treasury).owner() == REQUESTER, "Requester must own treasury");
        require(IBloomRegistry(registry).treasury() == treasury, "Treasury mismatch");
        require(IBloomRegistry(registry).bloom() == bloom, "BLOOM not bound or mismatch");
    }
}
