// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture, MockToken, ERC20Farm, Farm, RewardLedger} from "./helpers/Fixtures.sol";

contract EdgePropertiesTest is FarmFixture {
    function _future(uint8 d) internal returns (MockToken token, ERC20Farm target) {
        token = new MockToken(d);
        target = new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(token), d);
        _activate(target);
        vm.prank(alice);
        token.approve(address(target), type(uint256).max);
        vm.prank(bob);
        token.approve(address(target), type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DonationsAndRewardFundingCannotInflateAnySupportedDecimalPool(
        uint8 decimalsRaw,
        uint96 donationRaw,
        uint96 depositRaw
    ) public {
        uint8 d = uint8(bound(decimalsRaw, 0, 36));
        (MockToken token, ERC20Farm target) = _future(d);
        uint256 unit = 10 ** d;
        uint256 amount = bound(depositRaw, 1, 1000) * unit;
        uint256 donation = bound(donationRaw, 1, 1_000_000) * unit;
        token.mint(alice, unit);
        token.mint(bob, amount);
        vm.prank(alice);
        target.deposit(unit, alice, 1e18);
        uint256 quote = target.previewDeposit(amount);
        token.mint(address(target), donation);
        vm.startPrank(owner);
        bloom.approve(address(target), 100 ether);
        target.fundRewards(100 ether);
        vm.stopPrank();
        assertEq(target.previewDeposit(amount), quote);
        vm.prank(bob);
        assertEq(target.deposit(amount, bob, quote), quote);
        assertEq(target.accountedAssets(), unit + amount, "donation was pledged as principal");
        assertEq(target.excessBalance(address(token)), donation);
        vm.prank(owner);
        target.recoverExcess(address(token), payable(carol), donation);
        assertEq(token.balanceOf(carol), donation);
        vm.prank(owner);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        target.recoverExcess(address(token), payable(carol), 1);
        uint256 aliceShares = target.sharesOf(alice);
        vm.prank(alice);
        target.withdraw(aliceShares, payable(alice), 0);
        uint256 bobShares = target.sharesOf(bob);
        vm.prank(bob);
        target.withdraw(bobShares, payable(bob), 0);
        assertEq(token.balanceOf(address(target)), 0);
        assertEq(target.accountedAssets(), 0);
        assertEq(target.previewDeposit(unit), 1e18, "zero supply reset uses stale rate");
        assertEq(bloom.balanceOf(address(target)), 100 ether);
        _assertLedger(target);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RepeatedRoundTripsCannotExtractAnotherStakersBacking(
        uint8 decimalsRaw,
        uint96 amountRaw,
        uint8 cyclesRaw
    ) public {
        uint8 d = uint8(bound(decimalsRaw, 0, 36));
        (MockToken token, ERC20Farm target) = _future(d);
        uint256 unit = 10 ** d;
        uint256 amount = bound(amountRaw, 1, 1000) * unit;
        uint256 cycles = bound(cyclesRaw, 2, 16);
        token.mint(alice, 10_000 * unit);
        token.mint(bob, amount * cycles);
        vm.prank(alice);
        target.deposit(10_000 * unit, alice, 1);
        uint256 initialBob = token.balanceOf(bob);
        uint256 initialAliceClaim;
        (initialAliceClaim,,,) = target.previewRedeem(target.sharesOf(alice));
        for (uint256 i; i < cycles; ++i) {
            uint256 beforeBalance = token.balanceOf(bob);
            vm.startPrank(bob);
            uint256 minted = target.deposit(amount, bob, 1);
            target.withdraw(minted, payable(bob), 0);
            vm.stopPrank();
            assertLe(token.balanceOf(bob), beforeBalance, "round trip generated assets");
            assertEq(target.sharesOf(bob), 0);
            (uint256 aliceClaim,,,) = target.previewRedeem(target.sharesOf(alice));
            assertGe(aliceClaim, initialAliceClaim, "rounding stole another holder's backing");
        }
        assertEq(
            10_000 * unit + initialBob - token.balanceOf(bob),
            target.accountedAssets() + treasury.receivedFees(address(token)),
            "repeated-cycle conservation"
        );
    }

    /// @dev Total shares divide 1e36 exactly, isolating persistent user fractions from global dust.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ClaimFrequencyDoesNotEraseFractionalCredits(uint96 budgetRaw, uint8 countRaw) public {
        uint256 budget = bound(budgetRaw, 1, 1e24);
        uint256 count = bound(countRaw, 2, 24);
        _deposit(alice, 37 ether);
        _deposit(bob, 63 ether);
        _fund(budget);
        _start(budget, 1);
        uint256 start = block.timestamp;
        uint256 checkpoint = vm.snapshotState();
        vm.warp(start + 1 days);
        uint256 oneClaim = farm.pendingRewards(alice);
        uint256 otherClaim = farm.pendingRewards(bob);
        assertTrue(vm.revertToState(checkpoint));
        uint256 beforeBalance = bloom.balanceOf(alice);
        for (uint256 i = 1; i <= count; ++i) {
            vm.warp(start + 1 days * i / count);
            farm.checkpoint();
            if (farm.pendingRewards(alice) > 0) {
                vm.prank(alice);
                farm.claimRewards(alice);
            }
        }
        assertEq(bloom.balanceOf(alice) - beforeBalance, oneClaim);
        assertEq(farm.pendingRewards(bob), otherClaim);
        assertEq(farm.scheduledRewards(), 0);
        _assertLedger(farm);
    }

    function testOneWeiFinalExitTransfersAllDustToTreasuryAndCanReenter() public {
        _deposit(alice, 1);
        uint256 beforeBalance = bloom.balanceOf(alice);
        vm.prank(alice);
        farm.withdraw(1, payable(alice), 0);
        assertEq(bloom.balanceOf(alice), beforeBalance);
        assertEq(treasury.receivedFees(address(bloom)), 1);
        assertEq(farm.accountedAssets(), 0);
        assertEq(farm.totalShares(), 0);
        assertEq(_deposit(bob, 1), 1);
        _withdrawAll(bob);
        assertEq(treasury.receivedFees(address(bloom)), 2);
    }

    function testOneWeiPartialBurnCannotCollectFeeTwice() public {
        _deposit(alice, 1);
        _deposit(bob, 100);
        _withdrawAll(alice);
        assertEq(farm.accountedAssets(), 101);
        assertEq(farm.cumulativeRetainedFees(), 1);
        assertEq(treasury.receivedFees(address(bloom)), 0);
        uint256 beforeBalance = bloom.balanceOf(bob);
        _withdrawAll(bob);
        assertEq(bloom.balanceOf(bob) - beforeBalance, 85);
        assertEq(treasury.receivedFees(address(bloom)), 16);
        assertEq(farm.accountedAssets(), 0);
        assertEq(bloom.balanceOf(address(farm)), 0);
    }

    function testOldExitCreditSurvivesNewPoolAndEpochWithoutSubsidizingShares() public {
        _deposit(alice, 3);
        _deposit(bob, 4);
        _fund(10);
        _start(10, 1);
        vm.warp(block.timestamp + 1 days);
        _withdrawAll(alice);
        _withdrawAll(bob);
        assertEq(farm.rewardCredit(alice), 4);
        assertEq(farm.rewardCredit(bob), 5);
        assertEq(farm.unallocatedRewards(), 1);
        assertEq(_deposit(carol, 100), 100);
        vm.prank(owner);
        farm.restartEpoch(1, 1);
        assertEq(farm.pendingRewards(carol), 0);
        vm.warp(block.timestamp + 1 days);
        _withdrawAll(carol);
        assertEq(farm.rewardCredit(carol), 1);
        vm.prank(alice);
        assertEq(farm.claimRewards(alice), 4);
        vm.prank(bob);
        assertEq(farm.claimRewards(bob), 5);
        vm.prank(carol);
        assertEq(farm.claimRewards(carol), 1);
        assertEq(bloom.balanceOf(address(farm)), 0);
        assertEq(farm.paidRewards(), 10);
    }

    function testBeneficiaryGiftSettlesExistingSharesBeforeMintAndCallerCannotStealThem() public {
        _deposit(bob, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.warp(block.timestamp + 3 days);
        uint256 aliceBefore = bloom.balanceOf(alice);
        uint256 bobBefore = bloom.balanceOf(bob);
        vm.prank(alice);
        farm.deposit(50 ether, bob, 50 ether);
        assertEq(bloom.balanceOf(alice), aliceBefore - 50 ether);
        assertEq(bloom.balanceOf(bob), bobBefore);
        assertEq(farm.sharesOf(alice), 0);
        assertEq(farm.sharesOf(bob), 150 ether);
        assertEq(farm.pendingRewards(bob), 300 ether);
        vm.startPrank(alice);
        vm.expectRevert(Farm.InsufficientShares.selector);
        farm.withdraw(50 ether, payable(alice), 0);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        farm.claimRewards(alice);
        vm.stopPrank();
    }

    function test_RevertedWithdrawalRestoresLazyEpochStateSharesAndCredits() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert(Farm.Slippage.selector);
        farm.withdraw(100 ether, payable(bob), 85 ether + 1);
        assertEq(farm.segmentReleased(), 0);
        assertEq(farm.rewardPerShare(), 0);
        assertEq(farm.rewardIndexPaid(alice), 0);
        assertEq(farm.rewardCredit(alice), 0);
        assertEq(farm.scheduledRewards(), 1000 ether);
        assertEq(farm.sharesOf(alice), 100 ether);
        assertEq(farm.pendingRewards(alice), 300 ether);
        assertEq(treasury.receivedFees(address(bloom)), 0);
    }

    function testPrestartScheduleCanBeReplacedCancelledAndRecoveredWithoutAccrual() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        vm.prank(owner);
        farm.configureEpoch(700 ether, 10);
        vm.warp(block.timestamp + 365 days);
        vm.startPrank(owner);
        farm.configureEpoch(400 ether, 2);
        farm.recoverUnallocatedRewards(owner, 600 ether);
        farm.cancelFutureRewards();
        farm.recoverUnallocatedRewards(owner, 400 ether);
        vm.expectRevert(RewardLedger.EpochState.selector);
        farm.startEpoch();
        vm.stopPrank();
        assertEq(farm.pendingRewards(alice), 0);
        assertEq(farm.epochId(), 0);
        assertEq(farm.rewardReserve(), 0);
        assertEq(farm.accountedAssets(), 100 ether);
    }

    function test_RevertedContinueAtExactEndDoesNotLoseLastEmission() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        vm.expectRevert(RewardLedger.EpochState.selector);
        farm.continueEpoch(1, 1);
        assertEq(farm.pendingRewards(alice), 1000 ether);
        vm.prank(alice);
        assertEq(farm.claimRewards(alice), 1000 ether);
        assertFalse(farm.epochRunning());
        assertEq(farm.scheduledRewards(), 0);
        farm.checkpoint();
        assertEq(farm.paidRewards(), 1000 ether);
        assertEq(farm.pendingRewards(alice), 0);
    }

    function testDurationOverflowAtTimestampBoundaryRevertsBeforeReservingFunds() public {
        _fund(100);
        vm.warp(type(uint256).max - 1 days + 1);
        vm.prank(owner);
        vm.expectRevert(RewardLedger.InvalidDuration.selector);
        farm.configureEpoch(100, 1);
        assertEq(farm.unallocatedRewards(), 100);
        assertEq(farm.scheduledRewards(), 0);
        assertFalse(farm.epochConfigured());
    }
}
