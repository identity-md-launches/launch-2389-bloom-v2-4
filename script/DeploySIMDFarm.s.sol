// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StakedSIMD} from "../src/StakedSIMD.sol";
import {DeploymentInputs} from "./DeploymentInputs.sol";

contract DeploySIMDFarm {
    function run(address registry, address treasury, address bloom) external returns (StakedSIMD) {
        DeploymentInputs.checkFarm(registry, treasury, bloom);
        return new StakedSIMD(DeploymentInputs.REQUESTER, registry, treasury, bloom);
    }
}
