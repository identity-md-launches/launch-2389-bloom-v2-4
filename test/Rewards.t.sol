// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture, Farm, RewardLedger, MockToken, ERC20Farm} from "./helpers/Fixtures.sol";

contract RewardsTest is FarmFixture {
    function testFundingAndConfigurationNeverStartAccrual() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        vm.warp(block.timestamp + 20 days);
        assertEq(farm.pendingRewards(alice), 0);
        vm.prank(owner);
        farm.configureEpoch(1000 ether, 10);
        vm.warp(block.timestamp + 20 days);
        farm.checkpoint();
        assertEq(farm.pendingRewards(alice), 0);
        assertEq(farm.scheduledRewards(), 1000 ether);
        assertFalse(farm.epochRunning());
        vm.prank(owner);
        farm.startEpoch();
        vm.warp(block.timestamp + 1 days);
        assertEq(farm.pendingRewards(alice), 100 ether);
        _assertLedger(farm);
    }

    function testLateDepositorReceivesNoPastRewards() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.warp(block.timestamp + 5 days);
        _deposit(bob, 100 ether);
        assertEq(farm.pendingRewards(alice), 500 ether);
        assertEq(farm.pendingRewards(bob), 0);
        vm.warp(block.timestamp + 5 days);
        assertEq(farm.pendingRewards(alice), 750 ether);
        assertEq(farm.pendingRewards(bob), 250 ether);
        vm.prank(alice);
        farm.claimRewards(alice);
        vm.prank(bob);
        farm.claimRewards(bob);
        assertEq(farm.paidRewards(), 1000 ether);
        assertEq(farm.earnedUnpaidRewards(), 0);
        assertEq(farm.accountedAssets(), 200 ether);
        _assertLedger(farm);
    }

    function testFullExitRetainsClaimAndClaimHasNoFee() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.warp(block.timestamp + 4 days);
        _withdrawAll(alice);
        assertEq(farm.rewardCredit(alice), 400 ether);
        assertEq(farm.sharesOf(alice), 0);
        uint256 feesBefore = treasury.availableFees(address(bloom));
        uint256 beforeBalance = bloom.balanceOf(carol);
        vm.warp(block.timestamp + 100 days);
        vm.prank(alice);
        farm.claimRewards(carol);
        assertEq(bloom.balanceOf(carol) - beforeBalance, 400 ether);
        assertEq(treasury.availableFees(address(bloom)), feesBefore);
        assertEq(farm.unallocatedRewards(), 600 ether);
        assertEq(farm.skippedRewards(), 600 ether);
        assertFalse(farm.epochRunning());
        _assertLedger(farm);
    }

    function testZeroStakerIntervalsReturnToReserveAndNeverRetroactive() public {
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.warp(block.timestamp + 2 days);
        _deposit(alice, 100 ether);
        assertEq(farm.unallocatedRewards(), 200 ether);
        assertEq(farm.pendingRewards(alice), 0);
        vm.warp(block.timestamp + 1 days);
        _withdrawAll(alice);
        vm.warp(block.timestamp + 2 days);
        _deposit(bob, 100 ether);
        assertEq(farm.pendingRewards(bob), 0);
        assertEq(farm.pendingRewards(alice), 100 ether);
        assertEq(farm.skippedRewards(), 400 ether);
        vm.warp(block.timestamp + 5 days);
        farm.checkpoint();
        assertEq(farm.pendingRewards(bob), 500 ether);
        assertEq(farm.unallocatedRewards(), 400 ether);
        _assertLedger(farm);
    }

    function testContinueBoostAndRestartPreserveEarnedAndEpochIdentity() public {
        _deposit(alice, 100 ether);
        _fund(2000 ether);
        _start(1000 ether, 10);
        uint256 id = farm.epochId();
        uint256 start = farm.epochStartedAt();
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        farm.continueEpoch(1400 ether, 7);
        assertEq(farm.epochId(), id);
        assertEq(farm.epochStartedAt(), start);
        assertEq(farm.pendingRewards(alice), 300 ether);
        assertEq(farm.scheduledRewards(), 1400 ether);
        assertEq(farm.unallocatedRewards(), 300 ether);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        farm.restartEpoch(1000 ether, 10);
        assertEq(farm.epochId(), id + 1);
        assertEq(farm.pendingRewards(alice), 700 ether);
        assertEq(farm.unallocatedRewards(), 300 ether);
        assertEq(farm.earnedUnpaidRewards(), 700 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        farm.claimRewards(alice);
        assertEq(farm.paidRewards(), 800 ether);
        assertEq(farm.scheduledRewards(), 900 ether);
        _assertLedger(farm);
    }

    function testCannotPledgeEarnedRewardsTwiceOrRecoverObligations() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.warp(block.timestamp + 5 days);
        vm.startPrank(owner);
        vm.expectRevert(RewardLedger.InsufficientBudget.selector);
        farm.continueEpoch(501 ether, 5);
        vm.expectRevert(RewardLedger.InsufficientBudget.selector);
        farm.restartEpoch(501 ether, 5);
        vm.expectRevert(RewardLedger.InsufficientBudget.selector);
        farm.recoverUnallocatedRewards(owner, 1);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        farm.recoverExcess(address(bloom), payable(owner), 1);
        vm.stopPrank();
        assertEq(farm.pendingRewards(alice), 500 ether);
        assertEq(farm.accountedAssets(), 100 ether);
    }

    function testTopUpsStayFreeAndOnlyFreeFundsRecoverable() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.warp(block.timestamp + 2 days);
        _fund(700 ether);
        assertEq(farm.unallocatedRewards(), 700 ether);
        assertEq(farm.scheduledRewards(), 800 ether);
        assertEq(farm.pendingRewards(alice), 200 ether);
        vm.prank(owner);
        farm.recoverUnallocatedRewards(owner, 700 ether);
        assertEq(farm.rewardReserve(), 1000 ether);
        assertEq(farm.recoveredRewards(), 700 ether);
        _assertLedger(farm);
    }

    function testRoundingFractionsSurviveSettlementsAndDustReleasesOnlyAtZeroSupply() public {
        _deposit(alice, 3);
        _deposit(bob, 4);
        _fund(10);
        _start(10, 1);
        vm.warp(block.timestamp + 1 days);
        farm.checkpoint();
        assertEq(farm.pendingRewards(alice), 4);
        assertEq(farm.pendingRewards(bob), 5);
        assertEq(farm.earnedUnpaidRewards(), 10);
        _withdrawAll(alice);
        assertEq(farm.earnedUnpaidRewards(), 10);
        _withdrawAll(bob);
        assertEq(farm.totalCredits(), 9);
        assertEq(farm.earnedUnpaidRewards(), 9);
        assertEq(farm.unallocatedRewards(), 1);
        assertEq(farm.releasedRewardDust(), 1);
        vm.prank(owner);
        farm.recoverUnallocatedRewards(owner, 1);
        vm.prank(alice);
        farm.claimRewards(alice);
        vm.prank(bob);
        farm.claimRewards(bob);
        assertEq(bloom.balanceOf(address(farm)), 0);
        _assertLedger(farm);
    }

    function testFrequentClaimSettlementsPreserveSubWeiFractions() public {
        _deposit(alice, 3);
        _deposit(bob, 7);
        _fund(10);
        _start(10, 1);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= 10; ++i) {
            vm.warp(start + i * 8640);
            if (farm.pendingRewards(alice) != 0) {
                vm.prank(alice);
                farm.claimRewards(alice);
            }
        }
        assertEq(farm.paidRewards(), 3);
        assertEq(farm.pendingRewards(bob), 7);
        _assertLedger(farm);
    }

    function testPausedDepositsDoNotBlockClaimsWithdrawalOrAccrual() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.prank(owner);
        farm.setDepositsPaused(true);
        vm.prank(bob);
        vm.expectRevert(Farm.DepositsPaused.selector);
        farm.deposit(1 ether, bob, 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        farm.claimRewards(alice);
        _withdrawAll(alice);
        assertEq(farm.paidRewards(), 200 ether);
        _assertLedger(farm);
    }

    function testEpochBoundaryAndInvalidConfiguration() public {
        _fund(1000 ether);
        vm.startPrank(owner);
        vm.expectRevert(RewardLedger.EpochState.selector);
        farm.startEpoch();
        vm.expectRevert(RewardLedger.InvalidDuration.selector);
        farm.configureEpoch(1000 ether, 0);
        vm.expectRevert(RewardLedger.InvalidDuration.selector);
        farm.configureEpoch(1000 ether, type(uint256).max);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        farm.configureEpoch(0, 1);
        farm.configureEpoch(1000 ether, 1);
        farm.startEpoch();
        vm.expectRevert(RewardLedger.EpochState.selector);
        farm.startEpoch();
        vm.expectRevert(RewardLedger.EpochState.selector);
        farm.configureEpoch(100 ether, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        farm.checkpoint();
        vm.prank(owner);
        vm.expectRevert(RewardLedger.EpochState.selector);
        farm.continueEpoch(1, 1);
        vm.prank(owner);
        farm.configureEpoch(1000 ether, 2);
        assertTrue(farm.epochConfigured());
        _assertLedger(farm);
    }

    function testRewardTransferFailureRollsBackClaimAndCanRetry() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 1);
        vm.warp(block.timestamp + 1 days);
        bloom.setFail(true);
        vm.prank(alice);
        vm.expectRevert();
        farm.claimRewards(alice);
        assertEq(farm.pendingRewards(alice), 1000 ether);
        assertEq(farm.paidRewards(), 0);
        bloom.setFail(false);
        vm.prank(alice);
        farm.claimRewards(alice);
        assertEq(farm.paidRewards(), 1000 ether);
    }

    function testOversizedEpochCannotBrickOneShareAccrual() public {
        uint256 limit = type(uint256).max / farm.REWARD_PRECISION();
        bloom.mint(owner, limit + 1);
        _fund(limit + 1);
        _deposit(alice, 1);
        vm.startPrank(owner);
        vm.expectRevert(RewardLedger.AccountingLimit.selector);
        farm.configureEpoch(limit + 1, 1);
        farm.configureEpoch(limit, 1);
        farm.startEpoch();
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertEq(farm.pendingRewards(alice), limit);
        _withdrawAll(alice);
        vm.prank(alice);
        farm.claimRewards(alice);
        assertEq(farm.paidRewards(), limit);
        _assertLedger(farm);
    }

    function testFuzzRewardsSolventAcrossTimeAndShareEdits(
        uint96 a_,
        uint96 b_,
        uint96 reward_,
        uint32 elapsed_
    ) public {
        uint256 a = bound(uint256(a_), 100, 1e25);
        uint256 b = bound(uint256(b_), 100, 1e25);
        uint256 reward = bound(uint256(reward_), 1, 1e25);
        uint256 elapsed = bound(uint256(elapsed_), 0, 10 days);
        _deposit(alice, a);
        _fund(reward);
        _start(reward, 10);
        uint256 start = block.timestamp;
        vm.warp(start + elapsed);
        _deposit(bob, b);
        vm.warp(start + 10 days);
        _withdrawAll(alice);
        _withdrawAll(bob);
        if (farm.pendingRewards(alice) != 0) {
            vm.prank(alice);
            farm.claimRewards(alice);
        }
        if (farm.pendingRewards(bob) != 0) {
            vm.prank(bob);
            farm.claimRewards(bob);
        }
        assertEq(farm.earnedUnpaidRewards(), 0);
        assertEq(farm.totalCredits(), 0);
        assertEq(farm.scheduledRewards(), 0);
        assertEq(farm.unallocatedRewards() + farm.paidRewards(), reward);
        _assertLedger(farm);
    }
}
