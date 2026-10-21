// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Farm} from "./core/ERC20Farm.sol";

/// @notice BLOOM principal and BLOOM reward budgets share custody, but never share accounting.
contract StakedBLOOM is ERC20Farm {
    string public constant name = "stakedBLOOM";

    constructor(address owner_, address registry_, address treasury_, address bloom_, uint8 bloomDecimals_)
        ERC20Farm(owner_, registry_, treasury_, bloom_, bloom_, bloomDecimals_)
    {}
}
