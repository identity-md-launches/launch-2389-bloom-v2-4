// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture, Farm, StakedSIMD, StakedETH, MainnetAssets, IERC20} from "./Fixtures.sol";
import {IStakedIMD} from "src/interfaces/IBloom.sol";
import {OfficialIMD} from "../fixtures/OfficialIMD.sol";
import {OfficialSIMD} from "../fixtures/OfficialSIMD.sol";
import {OfficialWETH} from "../fixtures/OfficialWETH.sol";

contract NativeRejector {
    receive() external payable {
        revert("native rejected");
    }
}

/// @dev Recorded production bytecode, synthetic local state; no fork or network access.
abstract contract NetworkFixture is FarmFixture {
    StakedSIMD internal simdFarm;
    StakedETH internal ethFarm;
    IERC20 internal imd = IERC20(MainnetAssets.IMD);
    IERC20 internal simd = IERC20(MainnetAssets.SIMD);
    IERC20 internal weth = IERC20(MainnetAssets.WETH);
    IStakedIMD internal vault = IStakedIMD(MainnetAssets.SIMD);
    address[4] internal actors;
    Farm[3] internal allFarms;

    function setUp() public virtual override {
        super.setUp();
        vm.etch(MainnetAssets.IMD, OfficialIMD.runtime());
        vm.etch(MainnetAssets.SIMD, OfficialSIMD.runtime());
        vm.etch(MainnetAssets.WETH, OfficialWETH.runtime());
        vm.store(MainnetAssets.WETH, bytes32(uint256(2)), bytes32(uint256(18)));
        simdFarm = new StakedSIMD(owner, address(registry), address(treasury), address(bloom));
        ethFarm = new StakedETH(owner, address(registry), address(treasury), address(bloom));
        _activate(simdFarm);
        _activate(ethFarm);
        allFarms = [Farm(address(farm)), Farm(address(simdFarm)), Farm(address(ethFarm))];
        actors = [alice, bob, carol, address(new NativeRejector())];
        bloom.mint(actors[3], 1e30);
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            vm.deal(actor, 1e30);
            deal(address(imd), actor, 1e30, true);
            vm.startPrank(actor);
            bloom.approve(address(farm), type(uint256).max);
            imd.approve(address(vault), type(uint256).max);
            imd.approve(address(simdFarm), type(uint256).max);
            simd.approve(address(simdFarm), type(uint256).max);
            vault.deposit(1e24, actor);
            vm.stopPrank();
        }
        vm.startPrank(owner);
        bloom.approve(address(simdFarm), type(uint256).max);
        bloom.approve(address(ethFarm), type(uint256).max);
        vm.stopPrank();
    }
}
