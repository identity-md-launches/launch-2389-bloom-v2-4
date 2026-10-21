// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture, MockToken, ERC20Farm, Farm, RewardLedger} from "./helpers/Fixtures.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract AccountingTest is FarmFixture {
    function testPartialAndFinalExitConserveEveryUnit() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);
        uint256 beforeAlice = bloom.balanceOf(alice);
        vm.prank(alice);
        farm.withdraw(50 ether, payable(alice), 42.5 ether);
        assertEq(bloom.balanceOf(alice) - beforeAlice, 42.5 ether);
        assertEq(treasury.availableFees(address(bloom)), 0.5 ether);
        assertEq(farm.accountedAssets(), 157 ether);
        assertEq(farm.totalShares(), 150 ether);
        assertEq(farm.cumulativeRetainedFees(), 7 ether);
        // Partial withdrawal benefits the withdrawing user's remaining shares too.
        (uint256 gross,,,) = farm.previewRedeem(50 ether);
        assertGt(gross, 50 ether);
        _withdrawAll(alice);
        uint256 finalAssets = farm.accountedAssets();
        uint256 feeBefore = treasury.availableFees(address(bloom));
        uint256 beforeBob = bloom.balanceOf(bob);
        _withdrawAll(bob);
        uint256 expectedUser = Math.mulDiv(finalAssets, 85, 100);
        assertEq(bloom.balanceOf(bob) - beforeBob, expectedUser);
        assertEq(treasury.availableFees(address(bloom)) - feeBefore, finalAssets - expectedUser);
        assertEq(farm.accountedAssets(), 0);
        assertEq(farm.totalShares(), 0);
        assertEq(bloom.balanceOf(address(farm)), 0);
        assertEq(bloom.allowance(address(farm), address(treasury)), 0);
    }

    function testSameBlockFullExitNoCooldown() public {
        uint256 shares = _deposit(alice, 100 ether);
        vm.prank(alice);
        farm.withdraw(shares, payable(alice), 85 ether);
        assertEq(treasury.availableFees(address(bloom)), 15 ether);
        assertEq(farm.cumulativeRetainedFees(), 0);
    }

    function testDonationIsolationAndZeroSupplyReset() public {
        _deposit(alice, 1);
        bloom.mint(address(farm), 1e27);
        assertEq(farm.previewDeposit(100 ether), 100 ether);
        _deposit(bob, 100 ether);
        assertEq(farm.accountedAssets(), 100 ether + 1);
        assertEq(farm.excessBalance(address(bloom)), 1e27);
        _withdrawAll(bob);
        _withdrawAll(alice);
        assertEq(farm.accountedAssets(), 0);
        assertEq(farm.previewDeposit(5 ether), 5 ether);
        assertEq(farm.excessBalance(address(bloom)), 1e27);
        vm.prank(owner);
        farm.recoverExcess(address(bloom), payable(owner), 1e27);
        assertEq(bloom.balanceOf(address(farm)), 0);
    }

    function testRewardFundingNeverBacksBloomShares() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        assertEq(farm.previewDeposit(20 ether), 20 ether);
        assertEq(farm.accountedAssets(), 100 ether);
        assertEq(farm.excessBalance(address(bloom)), 0);
        _withdrawAll(alice);
        assertEq(bloom.balanceOf(address(farm)), 1000 ether);
        assertEq(farm.rewardReserve(), 1000 ether);
        _assertLedger(farm);
    }

    function testSlippageAndZeroInputsRevertAtomically() public {
        vm.startPrank(alice);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        farm.deposit(0, alice, 0);
        vm.expectRevert(Farm.Slippage.selector);
        farm.deposit(10 ether, alice, 10 ether + 1);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        farm.deposit(10 ether, address(0), 0);
        farm.deposit(100 ether, alice, 1);
        vm.expectRevert(Farm.Slippage.selector);
        farm.withdraw(100 ether, payable(alice), 85 ether + 1);
        vm.expectRevert(Farm.InsufficientShares.selector);
        farm.withdraw(100 ether + 1, payable(alice), 0);
        vm.expectRevert(Farm.InsufficientShares.selector);
        farm.withdraw(0, payable(alice), 0);
        vm.stopPrank();
        assertEq(farm.totalShares(), 100 ether);
        assertEq(farm.accountedAssets(), 100 ether);
    }

    function testDecimals24ZeroShareAndDecimals6FractionalShares() public {
        MockToken high = new MockToken(24);
        ERC20Farm highFarm =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(high), 24);
        _activate(highFarm);
        high.mint(alice, 1e24);
        vm.startPrank(alice);
        high.approve(address(highFarm), type(uint256).max);
        vm.expectRevert(Farm.ZeroShares.selector);
        highFarm.deposit(999_999, alice, 0);
        assertEq(highFarm.deposit(1e24, alice, 1e18), 1e18);
        vm.stopPrank();
        MockToken low = new MockToken(6);
        ERC20Farm lowFarm =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(low), 6);
        _activate(lowFarm);
        low.mint(alice, 1e6);
        vm.startPrank(alice);
        low.approve(address(lowFarm), 1e6);
        assertEq(lowFarm.deposit(1e6, alice, 1e18), 1e18);
        vm.stopPrank();
    }

    function testMeasuredNetDepositAndUnsupportedOutboundTaxRevert() public {
        bloom.setFee(100);
        _deposit(alice, 100 ether);
        assertEq(farm.accountedAssets(), 99 ether);
        assertEq(farm.totalShares(), 99 ether);
        vm.startPrank(alice);
        vm.expectRevert();
        farm.withdraw(99 ether, payable(alice), 0);
        vm.stopPrank();
        assertEq(farm.accountedAssets(), 99 ether);
        assertEq(treasury.availableFees(address(bloom)), 0);
        bloom.setFee(0);
        _withdrawAll(alice);
    }

    function testTokenFailureAndCallbackCannotStealShares() public {
        _deposit(alice, 100 ether);
        bloom.setCallback(address(farm), abi.encodeCall(farm.deposit, (1, bob, 0)));
        _deposit(bob, 100 ether);
        assertFalse(bloom.callbackSucceeded());
        bloom.setFail(true);
        vm.prank(alice);
        vm.expectRevert();
        farm.withdraw(100 ether, payable(alice), 0);
        assertEq(farm.sharesOf(alice), 100 ether);
        assertEq(farm.accountedAssets(), 200 ether);
    }

    function testSharesHaveNoTransferOrApprovalInterface() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        (bool ok,) = address(farm).call(abi.encodeWithSignature("transfer(address,uint256)", bob, 1 ether));
        assertFalse(ok);
        assertEq(farm.sharesOf(alice), 10 ether);
        assertEq(farm.sharesOf(bob), 0);
    }

    function testVirtualOffsetHeadroomPreservesExitAtUintLimit() public {
        MockToken token = new MockToken(18);
        ERC20Farm large =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(token), 18);
        _activate(large);
        uint256 ceiling = type(uint256).max;
        token.mint(alice, ceiling - 2);
        token.mint(bob, 2);
        vm.startPrank(alice);
        token.approve(address(large), ceiling);
        large.deposit(ceiling - 2, alice, 1);
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(large), 2);
        large.deposit(1, bob, 1);
        vm.expectRevert(RewardLedger.AccountingLimit.selector);
        large.deposit(1, bob, 1);
        vm.stopPrank();
        assertEq(large.accountedAssets(), ceiling - 1);
        vm.prank(alice);
        large.withdraw(ceiling - 2, payable(alice), 0);
        vm.prank(bob);
        large.withdraw(1, payable(bob), 0);
        assertEq(large.accountedAssets(), 0);
        assertEq(large.totalShares(), 0);
    }

    function testFuzzWithdrawConservation(uint128 rawA, uint128 rawB, uint64 rawPart) public {
        uint256 a = bound(uint256(rawA), 100, 1e28);
        uint256 b = bound(uint256(rawB), 100, 1e28);
        _deposit(alice, a);
        _deposit(bob, b);
        uint256 part = bound(uint256(rawPart), 2, a);
        (uint256 gross, uint256 user, uint256 fee, uint256 retained) = farm.previewRedeem(part);
        assertEq(gross, user + fee + retained);
        uint256 beforeBalance = bloom.balanceOf(address(farm));
        vm.prank(alice);
        farm.withdraw(part, payable(alice), user);
        assertEq(bloom.balanceOf(address(farm)), beforeBalance - user - fee);
        assertEq(farm.accountedAssets(), a + b - user - fee);
        if (farm.sharesOf(alice) != 0) _withdrawAll(alice);
        _withdrawAll(bob);
        assertEq(farm.totalShares(), 0);
        assertEq(farm.accountedAssets(), 0);
        assertEq(bloom.balanceOf(address(farm)), 0);
    }
}
