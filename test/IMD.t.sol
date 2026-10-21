// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture, StakedSIMD, Farm, RewardLedger, IERC20, MainnetAssets} from "./helpers/Fixtures.sol";
import {IStakedIMD} from "../src/interfaces/IBloom.sol";
import {OfficialSIMD} from "./fixtures/OfficialSIMD.sol";
import {OfficialIMD} from "./fixtures/OfficialIMD.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract IMDIntegrationTest is FarmFixture {
    StakedSIMD internal simdFarm;
    IERC20 internal imd = IERC20(MainnetAssets.IMD);
    IERC20 internal simd = IERC20(MainnetAssets.SIMD);
    IStakedIMD internal vault = IStakedIMD(MainnetAssets.SIMD);

    function setUp() public override {
        super.setUp();
        vm.etch(address(imd), OfficialIMD.runtime());
        vm.etch(address(simd), OfficialSIMD.runtime());
        deal(address(imd), alice, 10_000 ether, true);
        deal(address(imd), bob, 10_000 ether, true);
        deal(address(imd), carol, 10_000 ether, true);
        simdFarm = new StakedSIMD(owner, address(registry), address(treasury), address(bloom));
        _activate(simdFarm);
        vm.startPrank(alice);
        imd.approve(address(simdFarm), type(uint256).max);
        imd.approve(address(vault), type(uint256).max);
        simd.approve(address(simdFarm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        imd.approve(address(simdFarm), type(uint256).max);
        imd.approve(address(vault), type(uint256).max);
        simd.approve(address(simdFarm), type(uint256).max);
        vm.stopPrank();
    }

    function testOfficialDecimalsApprovalsAndDirectDeposit() public {
        assertEq(IERC20Metadata(address(simd)).decimals(), 24);
        assertEq(IERC20Metadata(address(imd)).decimals(), 18);
        assertEq(vault.asset(), address(imd));
        vm.startPrank(alice);
        uint256 received = vault.deposit(10 ether, alice);
        assertEq(received, 10e24);
        assertEq(simdFarm.deposit(received, alice, 10 ether), 10 ether);
        vm.stopPrank();
        assertEq(simdFarm.accountedAssets(), 10e24);
        assertEq(simdFarm.sharesOf(alice), 10 ether);
    }

    function testAtomicIMDDepositMeasuresNonOneToOneAndClearsApproval() public {
        vm.prank(bob);
        vault.deposit(100 ether, bob);
        vm.prank(carol);
        imd.transfer(address(vault), 100 ether);
        uint256 expectedSIMD = vault.convertToShares(100 ether);
        assertLt(expectedSIMD, 100e24);
        vm.prank(alice);
        uint256 shares = simdFarm.depositIMD(100 ether, alice, expectedSIMD, 1);
        assertEq(simd.balanceOf(address(simdFarm)), expectedSIMD);
        assertEq(simdFarm.accountedAssets(), expectedSIMD);
        assertEq(shares, expectedSIMD / 1e6);
        assertEq(imd.allowance(address(simdFarm), address(vault)), 0);
        assertEq(imd.balanceOf(address(simdFarm)), 0);
        assertEq(imd.balanceOf(alice), 9900 ether);
    }

    function testValueYieldDoesNotMintFarmAssetsOrShares() public {
        vm.prank(alice);
        simdFarm.depositIMD(100 ether, alice, 1, 1);
        uint256 backing = simdFarm.accountedAssets();
        uint256 shares = simdFarm.sharesOf(alice);
        uint256 valueBefore = vault.convertToAssets(backing);
        vm.prank(carol);
        imd.transfer(address(vault), 100 ether);
        assertEq(simdFarm.accountedAssets(), backing);
        assertEq(simdFarm.sharesOf(alice), shares);
        assertEq(simd.balanceOf(address(simdFarm)), backing);
        assertGt(vault.convertToAssets(backing), valueBefore);
    }

    function testOfficialHoldBlocksRedemptionButImmediateInKindExitWorks() public {
        vm.prank(alice);
        uint256 shares = simdFarm.depositIMD(100 ether, alice, 1, 1);
        assertEq(vault.maxRedeem(address(simdFarm)), 0);
        vm.prank(alice);
        simdFarm.withdraw(shares, payable(alice), 85e24);
        assertEq(simd.balanceOf(alice), 85e24);
        assertEq(simd.balanceOf(address(treasury)), 15e24);
        assertEq(simdFarm.accountedAssets(), 0);
        // The official hold follows the transferred sIMD. The farm introduces no hold itself.
        assertEq(vault.maxRedeem(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(85e24, alice, alice);
        vm.roll(block.number + 1);
        assertEq(vault.maxRedeem(alice), 85e24);
        vm.prank(alice);
        assertEq(vault.redeem(85e24, alice, alice), 85 ether);
    }

    function testIMDRedemptionExplicitlyDisabledEvenAfterHoldExpires() public {
        vm.prank(alice);
        uint256 shares = simdFarm.depositIMD(100 ether, alice, 1, 1);
        vm.roll(block.number + 1);
        assertFalse(simdFarm.imdRedemptionEnabled());
        vm.prank(alice);
        vm.expectRevert(StakedSIMD.IMDRedemptionDisabled.selector);
        simdFarm.withdrawIMD(shares, alice, 1);
        assertEq(simdFarm.sharesOf(alice), shares);
    }

    function testOfficialThirdPartyMintCanRestampHoldButCannotBlockSIMDExit() public {
        vm.prank(alice);
        uint256 shares = simdFarm.depositIMD(100 ether, alice, 1, 1);
        vm.roll(block.number + 1);
        assertGt(vault.maxRedeem(address(simdFarm)), 0);
        vm.prank(bob);
        vault.deposit(1, address(simdFarm));
        assertEq(vault.maxRedeem(address(simdFarm)), 0);
        assertEq(simdFarm.excessBalance(address(simd)), 1e6);
        vm.prank(alice);
        simdFarm.withdraw(shares, payable(alice), 85e24);
        assertEq(simdFarm.excessBalance(address(simd)), 1e6);
    }

    function testIMDConversionSlippageAndShareSlippageRollbackAllTransfers() public {
        uint256 before = imd.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(Farm.Slippage.selector);
        simdFarm.depositIMD(100 ether, alice, 100e24 + 1, 1);
        assertEq(imd.balanceOf(alice), before);
        vm.expectRevert(Farm.Slippage.selector);
        simdFarm.depositIMD(100 ether, alice, 1, 100 ether + 1);
        assertEq(imd.balanceOf(alice), before);
        assertEq(imd.allowance(address(simdFarm), address(vault)), 0);
        assertEq(simdFarm.accountedAssets(), 0);
        vm.stopPrank();
    }

    function testProtocolDepositFailureRollsBackAndNoDexFallback() public {
        // Model an external protocol failure: a call returns without consuming IMD or minting sIMD.
        vm.mockCall(
            address(vault),
            abi.encodeCall(vault.deposit, (100 ether, address(simdFarm))),
            abi.encode(uint256(0))
        );
        vm.prank(alice);
        vm.expectRevert(RewardLedger.InexactTransfer.selector);
        simdFarm.depositIMD(100 ether, alice, 1, 1);
        assertEq(imd.balanceOf(alice), 10_000 ether);
        assertEq(simdFarm.totalShares(), 0);
        assertEq(imd.allowance(address(simdFarm), address(vault)), 0);
    }

    function testFarmRewardsIndependentOfOfficialVaultYield() public {
        vm.prank(alice);
        simdFarm.depositIMD(100 ether, alice, 1, 1);
        vm.startPrank(owner);
        bloom.approve(address(simdFarm), 100 ether);
        simdFarm.fundRewards(100 ether);
        simdFarm.configureEpoch(100 ether, 1);
        simdFarm.startEpoch();
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        simdFarm.claimRewards(alice);
        assertEq(simdFarm.paidRewards(), 100 ether);
        assertEq(simdFarm.accountedAssets(), 100e24);
        assertEq(farm.rewardReserve(), 0);
        _assertLedger(simdFarm);
    }
}
