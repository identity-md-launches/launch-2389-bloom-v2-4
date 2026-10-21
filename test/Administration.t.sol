// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    FarmFixture,
    MockToken,
    ERC20Farm,
    StakedBLOOM,
    BloomFactory,
    BloomTreasury,
    Farm,
    RewardLedger
} from "./helpers/Fixtures.sol";
import {Managed} from "../src/core/Managed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AdministrationTest is FarmFixture {
    function testExplicitOwnerNeverWorkerOrFactory() public view {
        assertEq(registry.owner(), owner);
        assertEq(treasury.owner(), owner);
        assertEq(farm.owner(), owner);
        assertTrue(farm.owner() != address(this));
        assertTrue(farm.owner() != address(registry));
        assertEq(farm.pendingOwner(), address(0));
        assertEq(farm.renouncedPowers(), 0);
    }

    function testOnlyOwnerCanBindActivatePauseAllocateAndRecover() public {
        BloomTreasury t = new BloomTreasury(owner);
        BloomFactory r = new BloomFactory(owner, address(t));
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        t.bindRegistry(address(r));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        r.bindBloom(address(bloom));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        r.whitelistAsset(address(bloom), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        farm.setDepositsPaused(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        farm.fundRewards(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        farm.configureEpoch(1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        farm.activate();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        farm.recoverExcess(address(bloom), payable(bob), 1);
        vm.stopPrank();
    }

    function testBindingsAreOneTimeAndDependenciesCannotFrontRun() public {
        MockToken replacement = new MockToken(18);
        vm.startPrank(owner);
        vm.expectRevert(BloomFactory.AlreadyBound.selector);
        registry.bindBloom(address(replacement));
        vm.expectRevert(BloomTreasury.AlreadyBound.selector);
        treasury.bindRegistry(address(registry));
        vm.expectRevert(Farm.AlreadyActive.selector);
        farm.activate();
        vm.stopPrank();
    }

    function testFutureFarmRequiresWhitelistCorrectOwnerAndNoDuplicates() public {
        MockToken token = new MockToken(6);
        ERC20Farm future =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(token), 6);
        vm.startPrank(owner);
        vm.expectRevert(BloomFactory.NotWhitelisted.selector);
        registry.registerFarm(address(future));
        registry.whitelistAsset(address(token), true);
        registry.registerFarm(address(future));
        vm.expectRevert(BloomFactory.DuplicateFarm.selector);
        registry.registerFarm(address(future));
        ERC20Farm duplicate =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(token), 6);
        vm.expectRevert(BloomFactory.DuplicateFarm.selector);
        registry.registerFarm(address(duplicate));
        MockToken other = new MockToken(18);
        registry.whitelistAsset(address(other), true);
        ERC20Farm wrongOwner =
            new ERC20Farm(bob, address(registry), address(treasury), address(bloom), address(other), 18);
        vm.expectRevert(BloomFactory.InvalidFarm.selector);
        registry.registerFarm(address(wrongOwner));
        vm.stopPrank();
        assertEq(registry.farmCount(), 2);
    }

    function testCreate2FactoryDeploysFarmWithOwnerAndInitiallyDisabled() public {
        MockToken token = new MockToken(6);
        bytes memory initCode = abi.encodePacked(
            type(ERC20Farm).creationCode,
            abi.encode(owner, address(registry), address(treasury), address(bloom), address(token), uint8(6))
        );
        bytes32 salt = keccak256("future farm");
        address expected = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(registry), salt, keccak256(initCode)))
                )
            )
        );
        vm.startPrank(owner);
        registry.whitelistAsset(address(token), true);
        address deployed = registry.deployFarm(initCode, salt);
        vm.expectRevert(BloomFactory.DeploymentFailed.selector);
        registry.deployFarm(initCode, salt);
        vm.stopPrank();
        assertEq(deployed, expected);
        assertEq(ERC20Farm(deployed).owner(), owner);
        assertTrue(ERC20Farm(deployed).depositsPaused());
        assertFalse(ERC20Farm(deployed).active());
        assertFalse(ERC20Farm(deployed).epochRunning());
        assertTrue(registry.isFarm(deployed));
    }

    function testTwoStepOwnershipAndSelectivePermanentRenunciation() public {
        vm.prank(owner);
        farm.transferOwnership(bob);
        assertEq(farm.owner(), owner);
        assertEq(farm.pendingOwner(), bob);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        farm.acceptOwnership();
        vm.prank(bob);
        farm.acceptOwnership();
        assertEq(farm.owner(), bob);
        uint256 rewardsPower = farm.REWARDS();
        vm.startPrank(bob);
        farm.renouncePowers(rewardsPower);
        vm.expectRevert(abi.encodeWithSelector(Managed.PowerRenounced.selector, rewardsPower));
        farm.configureEpoch(1, 1);
        farm.setDepositsPaused(true);
        farm.setDepositsPaused(false);
        farm.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        farm.setDepositsPaused(true);
        vm.stopPrank();
        assertEq(farm.owner(), address(0));
        _deposit(alice, 10 ether);
        _withdrawAll(alice);
    }

    function testWhitelistGovernsAdmissionOnlyAndRenouncedPauseIsFinal() public {
        _deposit(alice, 100 ether);
        vm.startPrank(owner);
        farm.renouncePowers(farm.PAUSE());
        vm.expectRevert(abi.encodeWithSelector(Managed.PowerRenounced.selector, farm.PAUSE()));
        farm.setDepositsPaused(true);
        // De-whitelisting is not a second deposit switch for an active farm.
        registry.whitelistAsset(address(bloom), false);
        vm.stopPrank();
        _deposit(bob, 1 ether);
        _fund(1 ether);
        _start(1 ether, 1);
        assertTrue(farm.epochRunning());
        _withdrawAll(alice);
        _withdrawAll(bob);
        assertGt(treasury.availableFees(address(bloom)), 3 ether);
        // The whitelist still decides which assets may be registered.
        MockToken token = new MockToken(18);
        ERC20Farm future =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(token), 18);
        vm.prank(owner);
        vm.expectRevert(BloomFactory.NotWhitelisted.selector);
        registry.registerFarm(address(future));
    }

    function testTreasuryOnlySpendsReceivedFeesNotDonationsOrFarmFunds() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        bloom.mint(address(treasury), 10 ether);
        vm.startPrank(owner);
        vm.expectRevert(BloomTreasury.InvalidAmount.selector);
        treasury.spendFees(address(bloom), payable(owner), 1);
        vm.stopPrank();
        _withdrawAll(alice);
        assertEq(treasury.availableFees(address(bloom)), 15 ether);
        vm.prank(owner);
        treasury.spendFees(address(bloom), payable(carol), 15 ether);
        assertEq(treasury.availableFees(address(bloom)), 0);
        assertEq(bloom.balanceOf(address(treasury)), 10 ether);
        assertEq(bloom.balanceOf(address(farm)), 1000 ether);
        vm.prank(alice);
        vm.expectRevert(BloomTreasury.NotFarm.selector);
        treasury.receiveTokenFee(address(bloom), 1);
    }

    function testTreasuryFailedTransferRollsBackSpending() public {
        _deposit(alice, 100 ether);
        _withdrawAll(alice);
        bloom.setFail(true);
        vm.prank(owner);
        vm.expectRevert();
        treasury.spendFees(address(bloom), payable(carol), 15 ether);
        assertEq(treasury.availableFees(address(bloom)), 15 ether);
        assertEq(treasury.spentFees(address(bloom)), 0);
    }

    function testFarmThatCouldNeverActivateCannotTakeTheAssetSlot() public {
        MockToken token = new MockToken(6);
        ERC20Farm wrongDecimals =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(token), 18);
        vm.startPrank(owner);
        registry.whitelistAsset(address(token), true);
        vm.expectRevert(Farm.InvalidDependency.selector);
        registry.registerFarm(address(wrongDecimals));
        bytes memory badInitCode = abi.encodePacked(
            type(ERC20Farm).creationCode,
            abi.encode(owner, address(registry), address(treasury), address(bloom), address(token), uint8(18))
        );
        vm.expectRevert(Farm.InvalidDependency.selector);
        registry.deployFarm(badInitCode, bytes32(0));
        assertEq(registry.farmForAsset(address(token)), address(0));
        assertEq(registry.farmCount(), 1);
        ERC20Farm future =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(token), 6);
        vm.chainId(10);
        vm.expectRevert(Farm.WrongChain.selector);
        registry.registerFarm(address(future));
        vm.chainId(1);
        registry.registerFarm(address(future));
        assertEq(registry.farmForAsset(address(token)), address(future));
        vm.chainId(10);
        vm.expectRevert(Farm.WrongChain.selector);
        future.activate();
        vm.chainId(1);
        vm.expectRevert(Farm.NotActive.selector);
        future.setDepositsPaused(false);
        future.activate();
        assertTrue(future.active());
        vm.stopPrank();
    }

    function testStrandingRecipientsAreRejected() public {
        _deposit(alice, 10 ether);
        _fund(10 ether);
        _start(10 ether, 1);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(alice);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        farm.withdraw(1 ether, payable(address(treasury)), 0);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        farm.withdraw(1 ether, payable(address(registry)), 0);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        farm.withdraw(1 ether, payable(address(bloom)), 0);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        farm.claimRewards(address(treasury));
        farm.withdraw(1 ether, payable(bob), 0);
        farm.claimRewards(bob);
        vm.stopPrank();
        bloom.mint(address(farm), 1 ether);
        vm.startPrank(owner);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        farm.recoverExcess(address(bloom), payable(address(treasury)), 1 ether);
        farm.recoverExcess(address(bloom), payable(owner), 1 ether);
        vm.stopPrank();
    }

    function testUnboundAndUnregisteredContractsRejectActivation() public {
        BloomTreasury t = new BloomTreasury(owner);
        BloomFactory r = new BloomFactory(owner, address(t));
        StakedBLOOM f = new StakedBLOOM(owner, address(r), address(t), address(bloom), 18);
        vm.startPrank(owner);
        vm.expectRevert(Farm.InvalidDependency.selector);
        f.activate();
        r.bindBloom(address(bloom));
        r.whitelistAsset(address(bloom), true);
        r.registerFarm(address(f));
        vm.expectRevert(Farm.InvalidDependency.selector);
        f.activate();
        t.bindRegistry(address(r));
        f.activate();
        vm.stopPrank();
        assertTrue(f.depositsPaused());
        assertFalse(f.epochRunning());
        assertEq(f.epochId(), 0);
    }

    function testCancelledFutureBudgetIsFreeButAccruedClaimIsProtected() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _start(1000 ether, 10);
        vm.warp(block.timestamp + 3 days);
        vm.startPrank(owner);
        farm.cancelFutureRewards();
        farm.recoverUnallocatedRewards(owner, 700 ether);
        vm.expectRevert(RewardLedger.InsufficientBudget.selector);
        farm.recoverUnallocatedRewards(owner, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertEq(farm.pendingRewards(alice), 300 ether);
        _withdrawAll(alice);
        vm.prank(alice);
        farm.claimRewards(alice);
        _assertLedger(farm);
    }
}
