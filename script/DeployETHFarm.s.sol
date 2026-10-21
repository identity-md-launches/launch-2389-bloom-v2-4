// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StakedETH} from "../src/StakedETH.sol";
import {DeploymentInputs} from "./DeploymentInputs.sol";

contract DeployETHFarm {
    function run(address registry, address treasury, address bloom) external returns (StakedETH) {
        DeploymentInputs.checkFarm(registry, treasury, bloom);
        return new StakedETH(DeploymentInputs.REQUESTER, registry, treasury, bloom);
    }
}
