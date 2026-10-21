// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NetworkFixture} from "./helpers/NetworkFixture.sol";
import {
    FarmFixture,
    Farm,
    RewardLedger,
    StakedETH,
    StakedSIMD,
    MainnetAssets,
    IERC20
} from "./helpers/Fixtures.sol";
import {OfficialIMD} from "./fixtures/OfficialIMD.sol";
import {OfficialSIMD} from "./fixtures/OfficialSIMD.sol";
import {OfficialWETH} from "./fixtures/OfficialWETH.sol";
import {BloomTreasury} from "src/BloomTreasury.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract CheckpointReceiver {
    StakedETH internal immutable farm;
    bool public guardObserved;

    constructor(StakedETH farm_) {
        farm = farm_;
    }

    receive() external payable {
        (bool success, bytes memory reason) = address(farm).call(abi.encodeCall(farm.checkpoint, ()));
        guardObserved = !success && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
    }
}

contract IntegrationFailuresTest is NetworkFixture {
    using stdStorage for StdStorage;
    StdStorage private slots;

    function testPausedExternalVaultRollsBackIMDPathButStillAllowsDirectSIMDAndExit() public {
        // A dependency-failure simulation, not a claim that the renounced live vault can be paused.
        slots.target(address(vault)).sig("paused()").checked_write(true);
        uint256 beforeIMD = imd.balanceOf(alice);
        vm.prank(alice);
        // The verified ERC4626 checks its pause-aware maxDeposit before entering the deposit hook.
        vm.expectRevert(bytes4(keccak256("DepositMoreThanMax()")));
        simdFarm.depositIMD(100 ether, alice, 1, 1);
        assertEq(imd.balanceOf(alice), beforeIMD);
        assertEq(imd.allowance(address(simdFarm), address(vault)), 0);
        assertEq(simdFarm.totalShares(), 0);
        vm.startPrank(alice);
        uint256 shares = simdFarm.deposit(100e24, alice, 100 ether);
        simdFarm.withdraw(shares, payable(bob), 85e24);
        vm.stopPrank();
        assertEq(simdFarm.accountedAssets(), 0);
        assertEq(treasury.receivedFees(address(simd)), 15e24);
    }

    function testIMDDustAfterVaultYieldCannotProduceZeroFarmSharesOrTrapIMD() public {
        vm.prank(carol);
        imd.transfer(address(vault), 4e24);
        uint256 beforeIMD = imd.balanceOf(alice);
        uint256 beforeVaultIMD = imd.balanceOf(address(vault));
        uint256 beforeSupply = simd.totalSupply();
        assertGt(vault.convertToShares(1), 0);
        assertLt(vault.convertToShares(1), 1e6);
        vm.prank(alice);
        vm.expectRevert(Farm.ZeroShares.selector);
        simdFarm.depositIMD(1, alice, 0, 0);
        assertEq(imd.balanceOf(alice), beforeIMD);
        assertEq(imd.balanceOf(address(vault)), beforeVaultIMD);
        assertEq(simd.totalSupply(), beforeSupply);
        assertEq(imd.allowance(address(simdFarm), address(vault)), 0);
        assertEq(imd.balanceOf(address(simdFarm)), 0);
        assertEq(simd.balanceOf(address(simdFarm)), 0);
        assertEq(simdFarm.totalShares(), 0);
    }

    function testPreexistingIMDDonationIsNotConsumedByAtomicStaking() public {
        vm.prank(carol);
        imd.transfer(address(simdFarm), 5 ether);
        uint256 quote = vault.convertToShares(100 ether);
        vm.prank(alice);
        simdFarm.depositIMD(100 ether, bob, quote, 1);
        assertEq(imd.balanceOf(address(simdFarm)), 5 ether);
        assertEq(simdFarm.excessBalance(address(imd)), 5 ether);
        assertEq(simdFarm.accountedAssets(), quote);
        assertEq(simdFarm.sharesOf(alice), 0);
        assertEq(simdFarm.sharesOf(bob), 100 ether);
        vm.prank(owner);
        simdFarm.recoverExcess(address(imd), payable(carol), 5 ether);
        assertEq(imd.balanceOf(address(simdFarm)), 0);
        assertEq(simdFarm.accountedAssets(), quote);
        assertEq(imd.allowance(address(simdFarm), address(vault)), 0);
    }

    function testPausedFarmRejectsBothSIMDInputsWithoutMovingAnyTokens() public {
        vm.prank(owner);
        simdFarm.setDepositsPaused(true);
        uint256 beforeIMD = imd.balanceOf(alice);
        uint256 beforeSIMD = simd.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(Farm.DepositsPaused.selector);
        simdFarm.depositIMD(10 ether, alice, 0, 0);
        vm.expectRevert(Farm.DepositsPaused.selector);
        simdFarm.deposit(10e24, alice, 0);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), beforeIMD);
        assertEq(simd.balanceOf(alice), beforeSIMD);
        assertEq(simdFarm.totalShares(), 0);
        assertEq(imd.allowance(address(simdFarm), address(vault)), 0);
    }

    function testDelistingAnActiveFarmsAssetDoesNotPauseItsDeposits() public {
        // Whitelist governs registration only; the farm's own PAUSE power is the deposit switch.
        vm.prank(owner);
        registry.whitelistAsset(address(simd), false);
        vm.prank(alice);
        assertEq(simdFarm.deposit(10e24, alice, 10 ether), 10 ether);
        assertEq(simdFarm.accountedAssets(), 10e24);
    }

    function testFarmSpecificStrandingRecipientsAreRejectedOnDepositWithdrawAndClaim() public {
        vm.prank(alice);
        ethFarm.deposit{value: 10 ether}(alice, 1);
        vm.prank(alice);
        simdFarm.deposit(10e24, alice, 1);
        vm.startPrank(alice);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        ethFarm.withdraw(1 ether, payable(address(weth)), 0);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        ethFarm.deposit{value: 1 ether}(address(weth), 1);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        ethFarm.claimRewards(address(weth));
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        simdFarm.withdraw(1 ether, payable(address(imd)), 0);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        simdFarm.withdraw(1 ether, payable(address(simd)), 0);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        simdFarm.depositIMD(1 ether, address(imd), 0, 1);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        simdFarm.deposit(1e24, address(treasury), 1);
        vm.stopPrank();
        assertEq(ethFarm.sharesOf(alice), 10 ether);
        assertEq(simdFarm.sharesOf(alice), 10 ether);
        assertEq(weth.balanceOf(address(ethFarm)), 0);
        vm.deal(address(ethFarm), 11 ether);
        vm.prank(owner);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        ethFarm.recoverExcess(address(0), payable(address(weth)), 1 ether);
        assertEq(ethFarm.excessBalance(address(0)), 1 ether);
    }

    function testFallbackFailureRestoresNativeFeeAndAccruedRewardStateThenRetries() public {
        vm.prank(alice);
        ethFarm.deposit{value: 100 ether}(alice, 100 ether);
        vm.startPrank(owner);
        ethFarm.fundRewards(100 ether);
        ethFarm.configureEpoch(100 ether, 1);
        ethFarm.startEpoch();
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        address recipient = actors[3];
        uint256 recipientNative = recipient.balance;
        vm.mockCall(address(weth), abi.encodeCall(weth.transfer, (recipient, 85 ether)), abi.encode(false));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weth)));
        ethFarm.withdraw(100 ether, payable(recipient), 85 ether);
        assertEq(ethFarm.sharesOf(alice), 100 ether);
        assertEq(ethFarm.accountedAssets(), 100 ether);
        assertEq(address(ethFarm).balance, 100 ether);
        assertEq(ethFarm.segmentReleased(), 0);
        assertEq(ethFarm.rewardCredit(alice), 0);
        assertEq(ethFarm.pendingRewards(alice), 100 ether);
        assertEq(treasury.receivedFees(address(0)), 0);
        assertEq(address(treasury).balance, 0);
        assertEq(address(weth).balance, 0);
        assertEq(weth.balanceOf(recipient), 0);
        assertEq(weth.balanceOf(address(ethFarm)), 0);
        vm.clearMockedCalls();
        vm.prank(alice);
        ethFarm.withdraw(100 ether, payable(recipient), 85 ether);
        assertEq(weth.balanceOf(recipient), 85 ether);
        assertEq(recipient.balance, recipientNative);
        assertEq(ethFarm.rewardCredit(alice), 100 ether);
        vm.prank(alice);
        ethFarm.claimRewards(recipient);
        assertEq(ethFarm.rewardReserve(), 0);
        assertEq(treasury.receivedFees(address(0)), 15 ether);
    }

    function testNativeReceiverCannotCheckpointDuringWithdrawalButNativeDeliverySucceeds() public {
        CheckpointReceiver receiver = new CheckpointReceiver(ethFarm);
        vm.prank(alice);
        ethFarm.deposit{value: 10 ether}(alice, 1);
        vm.prank(alice);
        ethFarm.withdraw(10 ether, payable(address(receiver)), 8.5 ether);
        assertTrue(receiver.guardObserved());
        assertEq(address(receiver).balance, 8.5 ether);
        assertEq(weth.balanceOf(address(receiver)), 0);
        assertEq(treasury.receivedFees(address(0)), 1.5 ether);
    }

    function testRejectingNativeTreasurySpendRollsBackAndDoesNotWrap() public {
        vm.prank(alice);
        ethFarm.deposit{value: 100 ether}(alice, 1);
        vm.prank(alice);
        ethFarm.withdraw(100 ether, payable(alice), 85 ether);
        vm.prank(owner);
        vm.expectRevert(BloomTreasury.TransferFailed.selector);
        treasury.spendFees(address(0), payable(actors[3]), 15 ether);
        assertEq(treasury.availableFees(address(0)), 15 ether);
        assertEq(treasury.spentFees(address(0)), 0);
        assertEq(address(treasury).balance, 15 ether);
        assertEq(weth.balanceOf(actors[3]), 0);
        vm.prank(owner);
        treasury.spendFees(address(0), payable(carol), 15 ether);
        assertEq(treasury.availableFees(address(0)), 0);
    }

    function testRecoveringForcedNativeToRejectingRecipientIsAtomic() public {
        vm.prank(alice);
        ethFarm.deposit{value: 100 ether}(alice, 1);
        vm.deal(address(ethFarm), 107 ether);
        vm.prank(owner);
        vm.expectRevert(Farm.NativeTransferFailed.selector);
        ethFarm.recoverExcess(address(0), payable(actors[3]), 7 ether);
        assertEq(address(ethFarm).balance, 107 ether);
        assertEq(ethFarm.excessBalance(address(0)), 7 ether);
        assertEq(ethFarm.accountedAssets(), 100 ether);
    }

    function testRewardBudgetCannotBeBorrowedAcrossFarms() public {
        _fund(1000 ether);
        vm.startPrank(owner);
        vm.expectRevert(RewardLedger.InsufficientBudget.selector);
        simdFarm.configureEpoch(1, 1);
        vm.expectRevert(RewardLedger.InsufficientBudget.selector);
        ethFarm.configureEpoch(1, 1);
        vm.expectRevert(RewardLedger.InsufficientBudget.selector);
        simdFarm.recoverUnallocatedRewards(owner, 1);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        ethFarm.recoverExcess(address(bloom), payable(owner), 1);
        vm.stopPrank();
        assertEq(farm.rewardReserve(), 1000 ether);
        assertEq(simdFarm.rewardReserve(), 0);
        assertEq(ethFarm.rewardReserve(), 0);
    }
}

contract ActivationFailuresTest is FarmFixture {
    function testCanonicalWETHIdentityAndDecimalsAreRequiredBeforeRegistration() public {
        StakedETH target = new StakedETH(owner, address(registry), address(treasury), address(bloom));
        vm.startPrank(owner);
        registry.whitelistAsset(address(0), true);
        // No WETH runtime: registration itself refuses, so the native asset slot stays free.
        vm.expectRevert(Farm.InvalidDependency.selector);
        registry.registerFarm(address(target));
        vm.etch(MainnetAssets.WETH, OfficialWETH.runtime());
        // Matching runtime with uninitialized metadata still must not register.
        vm.expectRevert(Farm.InvalidDependency.selector);
        registry.registerFarm(address(target));
        assertFalse(registry.isFarm(address(target)));
        assertEq(registry.farmForAsset(address(0)), address(0));
        vm.store(MainnetAssets.WETH, bytes32(uint256(2)), bytes32(uint256(18)));
        registry.registerFarm(address(target));
        // A dependency that drifts after registration is still re-checked by activate().
        vm.mockCall(MainnetAssets.WETH, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.expectRevert(Farm.InvalidDependency.selector);
        target.activate();
        vm.clearMockedCalls();
        target.activate();
        vm.stopPrank();
        assertTrue(target.active());
        assertTrue(target.depositsPaused());
        assertFalse(target.epochRunning());
    }

    function testWrongChainRefusesRegistrationAndActivation() public {
        vm.etch(MainnetAssets.WETH, OfficialWETH.runtime());
        vm.store(MainnetAssets.WETH, bytes32(uint256(2)), bytes32(uint256(18)));
        StakedETH target = new StakedETH(owner, address(registry), address(treasury), address(bloom));
        vm.startPrank(owner);
        registry.whitelistAsset(address(0), true);
        vm.chainId(8453);
        vm.expectRevert(Farm.WrongChain.selector);
        registry.registerFarm(address(target));
        vm.chainId(1);
        registry.registerFarm(address(target));
        vm.chainId(8453);
        vm.expectRevert(Farm.WrongChain.selector);
        target.activate();
        vm.stopPrank();
        assertFalse(target.active());
    }

    function testOfficialSIMDMetadataAndCodeHashesMustAllMatch() public {
        vm.etch(MainnetAssets.IMD, OfficialIMD.runtime());
        vm.etch(MainnetAssets.SIMD, OfficialSIMD.runtime());
        StakedSIMD target = new StakedSIMD(owner, address(registry), address(treasury), address(bloom));
        vm.startPrank(owner);
        registry.whitelistAsset(MainnetAssets.SIMD, true);
        registry.registerFarm(address(target));
        vm.stopPrank();
        vm.mockCall(MainnetAssets.IMD, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.prank(owner);
        vm.expectRevert(Farm.InvalidDependency.selector);
        target.activate();
        vm.clearMockedCalls();
        vm.mockCall(MainnetAssets.SIMD, abi.encodeWithSignature("asset()"), abi.encode(address(bloom)));
        vm.prank(owner);
        vm.expectRevert(Farm.InvalidDependency.selector);
        target.activate();
        vm.clearMockedCalls();
        vm.etch(MainnetAssets.IMD, address(bloom).code);
        vm.prank(owner);
        vm.expectRevert(Farm.InvalidDependency.selector);
        target.activate();
        assertFalse(target.active());
        vm.etch(MainnetAssets.IMD, OfficialIMD.runtime());
        vm.prank(owner);
        target.activate();
        assertTrue(target.active());
        assertTrue(target.depositsPaused());
    }
}
