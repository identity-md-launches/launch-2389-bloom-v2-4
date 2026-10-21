// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture, ERC20Farm, Farm, RewardLedger, BloomTreasury} from "./helpers/Fixtures.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Only an external token test double; no farm methods are replaced.
contract ReturnVariantToken is ERC20 {
    uint8 public mode;
    address public callback;
    bool public callbackSucceeded;
    bytes4 public callbackError;

    constructor() ERC20("Return variant", "RET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(uint8 value) external {
        mode = value;
    }

    function setCallback(address target) external {
        callback = target;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        super.approve(spender, amount);
        return _returnValue();
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        super.transfer(recipient, amount);
        _probe();
        return _returnValue();
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        _probe();
        return _returnValue();
    }

    function _probe() private {
        if (callback == address(0)) return;
        bytes memory reason;
        (callbackSucceeded, reason) = callback.call(abi.encodeWithSignature("checkpoint()"));
        if (reason.length >= 4) callbackError = bytes4(reason);
    }

    function _returnValue() private view returns (bool) {
        if (mode == 1) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 2) return false;
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}

contract TokenFailuresTest is FarmFixture {
    ReturnVariantToken internal token;
    ERC20Farm internal target;

    function setUp() public override {
        super.setUp();
        token = new ReturnVariantToken();
        target =
            new ERC20Farm(owner, address(registry), address(treasury), address(bloom), address(token), 18);
        _activate(target);
        token.mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(address(target), type(uint256).max);
    }

    function testOptionalReturnTokenWorksThroughDepositFeePayoutAndTreasurySpend() public {
        token.setMode(1);
        vm.startPrank(alice);
        uint256 shares = target.deposit(100 ether, alice, 100 ether);
        target.withdraw(shares, payable(bob), 85 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.balanceOf(bob), 85 ether);
        assertEq(token.balanceOf(address(treasury)), 15 ether);
        assertEq(token.allowance(address(target), address(treasury)), 0);
        vm.prank(owner);
        treasury.spendFees(address(token), payable(carol), 15 ether);
        assertEq(token.balanceOf(carol), 15 ether);
        assertEq(treasury.availableFees(address(token)), 0);
        assertEq(target.accountedAssets(), 0);
    }

    function testFalseAndNonBooleanReturnsRollBackDepositsIncludingTokenSideEffects() public {
        for (uint8 mode = 2; mode <= 3; ++mode) {
            token.setMode(mode);
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
            );
            target.deposit(100 ether, alice, 1);
            assertEq(token.balanceOf(alice), 1000 ether);
            assertEq(token.balanceOf(address(target)), 0);
            assertEq(target.totalShares(), 0);
            assertEq(target.accountedAssets(), 0);
        }
    }

    function testFalseApproveOrTransferCannotBurnSharesOrRecordUnreceivedFees() public {
        vm.prank(alice);
        target.deposit(100 ether, alice, 1);
        token.setMode(2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        target.withdraw(100 ether, payable(bob), 85 ether);
        assertEq(token.balanceOf(address(target)), 100 ether);
        assertEq(target.sharesOf(alice), 100 ether);
        assertEq(target.accountedAssets(), 100 ether);
        assertEq(treasury.receivedFees(address(token)), 0);
        assertEq(token.allowance(address(target), address(treasury)), 0);
        token.setMode(0);
        vm.prank(alice);
        target.withdraw(100 ether, payable(bob), 85 ether);
        assertEq(token.balanceOf(bob), 85 ether);
    }

    function testTokenCallbackCannotCheckpointDuringInboundOrOutboundAccounting() public {
        token.setCallback(address(target));
        vm.prank(alice);
        target.deposit(100 ether, alice, 1);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        target.withdraw(100 ether, payable(bob), 85 ether);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(token.balanceOf(bob), 85 ether);
        assertEq(treasury.receivedFees(address(token)), 15 ether);
    }

    function testFundingCreditsOnlyNetReceiptAndDoesNotUseExistingPrincipal() public {
        _deposit(alice, 100 ether);
        bloom.setFee(1000);
        vm.prank(owner);
        assertEq(farm.fundRewards(100 ether), 90 ether);
        assertEq(farm.fundedRewards(), 90 ether);
        assertEq(farm.unallocatedRewards(), 90 ether);
        assertEq(farm.accountedAssets(), 100 ether);
        assertEq(bloom.balanceOf(address(farm)), 190 ether);
        bloom.setFee(0);
        vm.prank(owner);
        vm.expectRevert(RewardLedger.InsufficientBudget.selector);
        farm.configureEpoch(91 ether, 1);
        _start(90 ether, 1);
        vm.warp(block.timestamp + 1 days);
        _withdrawAll(alice);
        vm.prank(alice);
        assertEq(farm.claimRewards(alice), 90 ether);
        assertEq(bloom.balanceOf(address(farm)), 0);
    }

    function testZeroNetFundingAndZeroNetDepositRevertAtomically() public {
        bloom.setFee(10_000);
        uint256 beforeOwner = bloom.balanceOf(owner);
        uint256 beforeAlice = bloom.balanceOf(alice);
        vm.prank(owner);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        farm.fundRewards(100 ether);
        vm.prank(alice);
        vm.expectRevert(RewardLedger.InexactTransfer.selector);
        farm.deposit(100 ether, alice, 0);
        assertEq(bloom.balanceOf(owner), beforeOwner);
        assertEq(bloom.balanceOf(alice), beforeAlice);
        assertEq(farm.rewardReserve(), 0);
        assertEq(farm.accountedAssets(), 0);
        assertEq(farm.totalShares(), 0);
    }

    function testPartiallyTaxedDepositIsRefusedSoExitsCannotTakeOthersPrincipal() public {
        _deposit(bob, 100 ether);
        bloom.setFee(100);
        uint256 beforeAlice = bloom.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(RewardLedger.InexactTransfer.selector);
        farm.deposit(100 ether, alice, 0);
        assertEq(bloom.balanceOf(alice), beforeAlice);
        assertEq(farm.sharesOf(alice), 0);
        assertEq(farm.accountedAssets(), 100 ether);
        assertEq(bloom.balanceOf(address(farm)), 100 ether);
    }

    function testTaxedRewardClaimCannotConsumeCreditAndCanBeRetried() public {
        _deposit(alice, 100 ether);
        _fund(100 ether);
        _start(100 ether, 1);
        vm.warp(block.timestamp + 1 days);
        _withdrawAll(alice);
        uint256 beforeBalance = bloom.balanceOf(bob);
        bloom.setFee(100);
        vm.prank(alice);
        vm.expectRevert(RewardLedger.InexactTransfer.selector);
        farm.claimRewards(bob);
        assertEq(bloom.balanceOf(bob), beforeBalance);
        assertEq(farm.rewardCredit(alice), 100 ether);
        assertEq(farm.totalCredits(), 100 ether);
        assertEq(farm.earnedUnpaidRewards(), 100 ether);
        assertEq(farm.paidRewards(), 0);
        bloom.setFee(0);
        vm.prank(alice);
        assertEq(farm.claimRewards(bob), 100 ether);
    }

    function testTaxedTreasurySpendRestoresFeeAllowanceAndRecipientBalance() public {
        _deposit(alice, 100 ether);
        _withdrawAll(alice);
        uint256 beforeBalance = bloom.balanceOf(carol);
        bloom.setFee(1000);
        vm.prank(owner);
        vm.expectRevert(BloomTreasury.TransferFailed.selector);
        treasury.spendFees(address(bloom), payable(carol), 15 ether);
        assertEq(bloom.balanceOf(carol), beforeBalance);
        assertEq(bloom.balanceOf(address(treasury)), 15 ether);
        assertEq(treasury.spentFees(address(bloom)), 0);
        assertEq(treasury.availableFees(address(bloom)), 15 ether);
    }

    function testTaxedExcessRecoveryCannotTouchBackingOrRewardReserve() public {
        _deposit(alice, 100 ether);
        _fund(100 ether);
        bloom.mint(address(farm), 10 ether);
        bloom.setFee(1000);
        vm.prank(owner);
        vm.expectRevert(RewardLedger.InexactTransfer.selector);
        farm.recoverExcess(address(bloom), payable(carol), 10 ether);
        assertEq(farm.excessBalance(address(bloom)), 10 ether);
        assertEq(farm.rewardReserve(), 100 ether);
        assertEq(farm.accountedAssets(), 100 ether);
        assertEq(bloom.balanceOf(address(farm)), 210 ether);
    }
}
