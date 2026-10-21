// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    FarmFixture,
    MockToken,
    ERC20Farm,
    Farm,
    RewardLedger,
    BloomFactory,
    BloomTreasury
} from "./helpers/Fixtures.sol";
import {Managed} from "src/core/Managed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AuthorityFailuresTest is FarmFixture {
    event Deposit(address indexed caller, address indexed beneficiary, uint256 assets, uint256 shares);
    event Withdrawal(
        address indexed user,
        address indexed beneficiary,
        uint256 shares,
        uint256 grossAssets,
        uint256 userAssets
    );
    event WithdrawalFee(uint256 grossAssets, uint256 treasuryAssets, uint256 retainedAssets, bool finalExit);
    event RewardClaimed(address indexed user, address indexed recipient, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 amount);
    event EpochConfigured(uint256 amount, uint256 duration);
    event EpochStarted(uint256 indexed epochId, uint256 amount, uint256 start, uint256 end);
    event DepositsPauseSet(bool paused);
    event PowersRenounced(address indexed owner, uint256 powers);
    event FeesSpent(address indexed asset, address indexed recipient, uint256 amount);

    function _denied(address target, bytes memory input) internal {
        vm.prank(carol);
        (bool ok, bytes memory reason) = target.call(input);
        assertFalse(ok, "unprivileged call succeeded");
        assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
    }

    function testEveryPrivilegedFarmEntryRejectsUnprivilegedCaller() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        bytes[] memory calls = new bytes[](14);
        calls[0] = abi.encodeCall(farm.activate, ());
        calls[1] = abi.encodeCall(farm.setDepositsPaused, (true));
        calls[2] = abi.encodeCall(farm.fundRewards, (1));
        calls[3] = abi.encodeCall(farm.configureEpoch, (1, 1));
        calls[4] = abi.encodeCall(farm.startEpoch, ());
        calls[5] = abi.encodeCall(farm.restartEpoch, (1, 1));
        calls[6] = abi.encodeCall(farm.continueEpoch, (1, 1));
        calls[7] = abi.encodeCall(farm.cancelFutureRewards, ());
        calls[8] = abi.encodeCall(farm.recoverUnallocatedRewards, (carol, 1));
        calls[9] = abi.encodeCall(farm.recoverExcess, (address(bloom), payable(carol), 1));
        calls[10] = abi.encodeCall(farm.renouncePowers, (31));
        calls[11] = abi.encodeCall(farm.transferOwnership, (carol));
        calls[12] = abi.encodeCall(farm.renounceOwnership, ());
        calls[13] = abi.encodeCall(farm.acceptOwnership, ());
        for (uint256 i; i < calls.length; ++i) {
            _denied(address(farm), calls[i]);
        }
        assertEq(farm.owner(), owner);
        assertEq(farm.accountedAssets(), 100 ether);
        assertEq(farm.rewardReserve(), 1000 ether);
        assertFalse(farm.depositsPaused());
    }

    function testFactoryAndTreasuryCannotBeReconfiguredByDepositor() public {
        _denied(address(registry), abi.encodeCall(registry.registerFarm, (address(farm))));
        _denied(address(registry), abi.encodeCall(registry.deployFarm, (hex"00", bytes32(0))));
        _denied(address(registry), abi.encodeCall(registry.whitelistAsset, (address(bloom), false)));
        _denied(address(registry), abi.encodeCall(registry.bindBloom, (address(bloom))));
        _denied(address(registry), abi.encodeCall(registry.renouncePowers, (1)));
        _denied(address(treasury), abi.encodeCall(treasury.bindRegistry, (address(registry))));
        _denied(address(treasury), abi.encodeCall(treasury.spendFees, (address(bloom), payable(carol), 1)));
        _denied(address(treasury), abi.encodeCall(treasury.renouncePowers, (16)));
        assertEq(registry.farmCount(), 1);
        assertTrue(registry.isAssetWhitelisted(address(bloom)));
    }

    function testUnregisteredCallersCannotPretendDonationsAreTreasuryFees() public {
        bloom.mint(address(treasury), 100 ether);
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert(BloomTreasury.NotFarm.selector);
        treasury.receiveTokenFee(address(bloom), 100 ether);
        vm.expectRevert(BloomTreasury.NotFarm.selector);
        treasury.receiveNativeFee{value: 1 ether}();
        vm.stopPrank();
        assertEq(treasury.availableFees(address(bloom)), 0);
        assertEq(treasury.availableFees(address(0)), 0);
        assertEq(address(treasury).balance, 0);
    }

    function testRecoveryRenunciationSurvivesOwnershipTransferButClaimsAndExitsWork() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        uint256 recovery = farm.RECOVERY();
        vm.startPrank(owner);
        farm.renouncePowers(recovery);
        farm.transferOwnership(bob);
        vm.stopPrank();
        vm.prank(bob);
        farm.acceptOwnership();
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(bob);
        farm.cancelFutureRewards();
        vm.expectRevert(abi.encodeWithSelector(Managed.PowerRenounced.selector, recovery));
        farm.recoverUnallocatedRewards(bob, 900 ether);
        vm.expectRevert(abi.encodeWithSelector(Managed.PowerRenounced.selector, recovery));
        farm.recoverExcess(address(bloom), payable(bob), 1);
        farm.setDepositsPaused(true);
        vm.stopPrank();
        _withdrawAll(alice);
        vm.prank(alice);
        assertEq(farm.claimRewards(alice), 100 ether);
        assertEq(farm.renouncedPowers(), recovery);
    }

    function testAllRewardOperationsHonorRenunciationWithoutTouchingUserObligations() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 1);
        uint256 power = farm.REWARDS();
        vm.prank(owner);
        farm.renouncePowers(power);
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(farm.fundRewards, (1));
        calls[1] = abi.encodeCall(farm.configureEpoch, (1, 1));
        calls[2] = abi.encodeCall(farm.startEpoch, ());
        calls[3] = abi.encodeCall(farm.restartEpoch, (1, 1));
        calls[4] = abi.encodeCall(farm.continueEpoch, (1, 1));
        calls[5] = abi.encodeCall(farm.cancelFutureRewards, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(owner);
            (bool ok, bytes memory reason) = address(farm).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(Managed.PowerRenounced.selector, power));
        }
        vm.warp(block.timestamp + 1 days);
        _withdrawAll(alice);
        vm.prank(alice);
        assertEq(farm.claimRewards(alice), 1000 ether);
    }

    function testConfigPauseAndSpendPowersCanBeRenouncedIndependently() public {
        _deposit(alice, 100 ether);
        _withdrawAll(alice);
        vm.startPrank(owner);
        registry.renouncePowers(1);
        vm.expectRevert(abi.encodeWithSelector(Managed.PowerRenounced.selector, uint256(1)));
        registry.whitelistAsset(address(bloom), false);
        farm.renouncePowers(4);
        vm.expectRevert(abi.encodeWithSelector(Managed.PowerRenounced.selector, uint256(4)));
        farm.setDepositsPaused(true);
        farm.fundRewards(10 ether);
        treasury.renouncePowers(16);
        vm.expectRevert(abi.encodeWithSelector(Managed.PowerRenounced.selector, uint256(16)));
        treasury.spendFees(address(bloom), payable(owner), 1);
        vm.stopPrank();
        assertEq(treasury.availableFees(address(bloom)), 15 ether);
        _deposit(bob, 100 ether);
        _withdrawAll(bob);
        assertEq(treasury.availableFees(address(bloom)), 30 ether);
    }

    function testInvalidRenunciationMasksHaveNoEffect() public {
        vm.startPrank(owner);
        vm.expectRevert(Managed.InvalidPower.selector);
        farm.renouncePowers(0);
        vm.expectRevert(Managed.InvalidPower.selector);
        farm.renouncePowers(32);
        vm.expectRevert(Managed.InvalidPower.selector);
        farm.renouncePowers(type(uint256).max);
        vm.stopPrank();
        assertEq(farm.renouncedPowers(), 0);
        _deposit(alice, 1 ether);
        _withdrawAll(alice);
    }

    function test_RevertedCreate2RegistrationRollsBackCreationAndSaltRemainsUsable() public {
        MockToken token = new MockToken(6);
        bytes memory code = abi.encodePacked(
            type(ERC20Farm).creationCode,
            abi.encode(owner, address(registry), address(treasury), address(bloom), address(token), uint8(6))
        );
        bytes32 salt = keccak256("registration rollback");
        address predicted = registry.predictFarmAddress(keccak256(code), salt);
        vm.startPrank(owner);
        vm.expectRevert(BloomFactory.NotWhitelisted.selector);
        registry.deployFarm(code, salt);
        assertEq(predicted.code.length, 0);
        assertEq(registry.farmCount(), 1);
        assertFalse(registry.isFarm(predicted));
        registry.whitelistAsset(address(token), true);
        assertEq(registry.deployFarm(code, salt), predicted);
        vm.stopPrank();
        assertGt(predicted.code.length, 0);
        assertEq(registry.farmForAsset(address(token)), predicted);
        assertEq(ERC20Farm(predicted).owner(), owner);
        assertFalse(ERC20Farm(predicted).active());
    }

    function testMalformedInitCodeAndOversizedInputCannotPolluteRegistry() public {
        bytes memory oversized = new bytes(49_153);
        vm.startPrank(owner);
        vm.expectRevert(BloomFactory.DeploymentFailed.selector);
        registry.deployFarm(hex"", bytes32(0));
        vm.expectRevert(BloomFactory.DeploymentFailed.selector);
        registry.deployFarm(oversized, bytes32(0));
        vm.expectRevert(BloomFactory.DeploymentFailed.selector);
        registry.deployFarm(hex"60006000fd", bytes32(0));
        vm.expectRevert(BloomFactory.InvalidFarm.selector);
        registry.deployFarm(hex"00", bytes32(0));
        vm.stopPrank();
        assertEq(registry.farmCount(), 1);
    }

    function testTreasuryBindingRejectsWrongOwnerWrongTreasuryAndNoCode() public {
        BloomTreasury target = new BloomTreasury(owner);
        BloomFactory wrongOwner = new BloomFactory(bob, address(target));
        BloomFactory wrongTreasury = new BloomFactory(owner, address(treasury));
        vm.startPrank(owner);
        vm.expectRevert(BloomTreasury.InvalidRegistry.selector);
        target.bindRegistry(alice);
        vm.expectRevert(BloomTreasury.InvalidRegistry.selector);
        target.bindRegistry(address(wrongOwner));
        vm.expectRevert(BloomTreasury.InvalidRegistry.selector);
        target.bindRegistry(address(wrongTreasury));
        vm.stopPrank();
        assertEq(target.registry(), address(0));
    }

    function testDepositWithdrawalFeeAndClaimEventsMatchActualAmounts() public {
        vm.expectEmit(true, true, false, true, address(farm));
        emit Deposit(alice, bob, 100 ether, 100 ether);
        vm.prank(alice);
        farm.deposit(100 ether, bob, 1);
        _fund(100 ether);
        _start(100 ether, 1);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, false, true, address(farm));
        emit Withdrawal(bob, carol, 100 ether, 100 ether, 85 ether);
        vm.expectEmit(false, false, false, true, address(farm));
        emit WithdrawalFee(100 ether, 15 ether, 0, true);
        vm.prank(bob);
        farm.withdraw(100 ether, payable(carol), 85 ether);
        vm.expectEmit(true, true, false, true, address(farm));
        emit RewardClaimed(bob, alice, 100 ether);
        vm.prank(bob);
        farm.claimRewards(alice);
        assertEq(treasury.receivedFees(address(bloom)), 15 ether);
        assertEq(farm.paidRewards(), 100 ether);
    }

    function testEpochPauseRoleAndTreasurySpendEvents() public {
        vm.expectEmit(true, false, false, true, address(farm));
        emit RewardsFunded(owner, 100 ether);
        _fund(100 ether);
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(farm));
        emit EpochConfigured(100 ether, 2 days);
        farm.configureEpoch(100 ether, 2);
        vm.expectEmit(true, false, false, true, address(farm));
        emit EpochStarted(1, 100 ether, block.timestamp, block.timestamp + 2 days);
        farm.startEpoch();
        vm.expectEmit(false, false, false, true, address(farm));
        emit DepositsPauseSet(true);
        farm.setDepositsPaused(true);
        vm.expectEmit(true, false, false, true, address(farm));
        emit PowersRenounced(owner, 8);
        farm.renouncePowers(8);
        farm.setDepositsPaused(false);
        vm.stopPrank();
        _deposit(alice, 100 ether);
        _withdrawAll(alice);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit FeesSpent(address(bloom), carol, 15 ether);
        vm.prank(owner);
        treasury.spendFees(address(bloom), payable(carol), 15 ether);
        assertEq(treasury.availableFees(address(bloom)), 0);
    }
}
