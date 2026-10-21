// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StakedBLOOM} from "../src/StakedBLOOM.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeploymentInputs} from "./DeploymentInputs.sol";

contract DeployBLOOMFarm {
    function run(address registry, address treasury, address bloom, uint8 bloomDecimals)
        external
        returns (StakedBLOOM)
    {
        DeploymentInputs.checkFarm(registry, treasury, bloom);
        require(IERC20Metadata(bloom).decimals() == bloomDecimals, "BLOOM decimals mismatch");
        return new StakedBLOOM(DeploymentInputs.REQUESTER, registry, treasury, bloom, bloomDecimals);
    }
}
