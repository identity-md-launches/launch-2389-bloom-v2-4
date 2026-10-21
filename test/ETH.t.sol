// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture, StakedETH, Farm, RewardLedger, IERC20, MainnetAssets} from "./helpers/Fixtures.sol";
import {OfficialWETH} from "./fixtures/OfficialWETH.sol";

contract RejectETH {
    receive() external payable {
        revert("NO_ETH");
    }
}

contract ExhaustGas {
    receive() external payable {
        assembly { for {} 1 {} {} }
    }
}

contract RevertDataBomb {
    receive() external payable {
        assembly {
            revert(0, 131072)
        }
    }
}

contract ReenterETH {
    StakedETH public farm;
    bool public blocked;

    constructor(StakedETH f) {
        farm = f;
    }

    function exit() external {
        farm.withdraw(farm.sharesOf(address(this)), payable(address(this)), 0);
    }

    receive() external payable {
        (bool ok,) = address(farm).call(abi.encodeCall(farm.withdraw, (1, payable(address(this)), 0)));
        blocked = !ok;
    }
}

contract BrokenWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract RevertingWETH {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function deposit() external payable {
        revert("WRAP_FAILED");
    }
}

contract ETHTest is FarmFixture {
    StakedETH internal ethFarm;
    address internal weth = MainnetAssets.WETH;

    function setUp() public override {
        super.setUp();
        vm.etch(weth, OfficialWETH.runtime());
        // Canonical WETH9's decimals is constructor-initialized storage slot 2.
        vm.store(weth, bytes32(uint256(2)), bytes32(uint256(18)));
        ethFarm = new StakedETH(owner, address(registry), address(treasury), address(bloom));
        _activate(ethFarm);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _depositETH(address user, uint256 amount, address beneficiary) internal returns (uint256) {
        vm.prank(user);
        return ethFarm.deposit{value: amount}(beneficiary, 1);
    }

    function testNativePartialAndFullExit() public {
        _depositETH(alice, 100 ether, alice);
        _depositETH(bob, 100 ether, bob);
        uint256 beforeBalance = alice.balance;
        vm.prank(alice);
        ethFarm.withdraw(100 ether, payable(alice), 85 ether);
        assertEq(alice.balance - beforeBalance, 85 ether);
        assertEq(address(treasury).balance, 1 ether);
        assertEq(ethFarm.accountedAssets(), 114 ether);
        vm.prank(bob);
        ethFarm.withdraw(100 ether, payable(bob), 96.9 ether);
        assertEq(ethFarm.accountedAssets(), 0);
        assertEq(address(ethFarm).balance, 0);
        assertEq(treasury.availableFees(address(0)), 18.1 ether);
        _assertLedger(ethFarm);
    }

    function testRejectingBeneficiaryReceivesCanonicalWETHWithNoExtraFee() public {
        RejectETH beneficiary = new RejectETH();
        _depositETH(alice, 100 ether, alice);
        vm.prank(alice);
        ethFarm.withdraw(100 ether, payable(address(beneficiary)), 85 ether);
        assertEq(address(beneficiary).balance, 0);
        assertEq(IERC20(weth).balanceOf(address(beneficiary)), 85 ether);
        assertEq(IERC20(weth).balanceOf(alice), 0);
        assertEq(treasury.availableFees(address(0)), 15 ether);
        assertEq(address(ethFarm).balance, 0);
        assertEq(IERC20(weth).balanceOf(address(ethFarm)), 0);
    }

    function testWETHAndTreasuryBeneficiariesAreRejectedBeforeAnyPayout() public {
        _depositETH(alice, 10 ether, alice);
        vm.startPrank(alice);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        ethFarm.withdraw(10 ether, payable(weth), 0);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        ethFarm.withdraw(10 ether, payable(address(treasury)), 0);
        vm.expectRevert(RewardLedger.InvalidAddress.selector);
        ethFarm.deposit{value: 1 ether}(weth, 0);
        vm.stopPrank();
        assertEq(ethFarm.sharesOf(alice), 10 ether);
        assertEq(IERC20(weth).balanceOf(address(ethFarm)), 0);
        assertEq(IERC20(weth).balanceOf(address(treasury)), 0);
        assertEq(address(ethFarm).balance, 10 ether);
    }

    function testGasGriefCannotPreventWETHFallback() public {
        ExhaustGas beneficiary = new ExhaustGas();
        _depositETH(alice, 10 ether, alice);
        vm.prank(alice);
        ethFarm.withdraw(10 ether, payable(address(beneficiary)), 8.5 ether);
        assertEq(IERC20(weth).balanceOf(address(beneficiary)), 8.5 ether);
    }

    function testLargeRevertDataCannotPreventWETHFallback() public {
        RevertDataBomb beneficiary = new RevertDataBomb();
        _depositETH(alice, 10 ether, alice);
        vm.prank(alice);
        ethFarm.withdraw(10 ether, payable(address(beneficiary)), 8.5 ether);
        assertEq(IERC20(weth).balanceOf(address(beneficiary)), 8.5 ether);
        assertEq(treasury.availableFees(address(0)), 1.5 ether);
    }

    function testBothDeliveryPathsFailAtomically() public {
        RejectETH beneficiary = new RejectETH();
        _depositETH(alice, 100 ether, alice);
        vm.etch(weth, address(new BrokenWETH()).code);
        vm.prank(alice);
        vm.expectRevert();
        ethFarm.withdraw(100 ether, payable(address(beneficiary)), 0);
        assertEq(ethFarm.sharesOf(alice), 100 ether);
        assertEq(ethFarm.accountedAssets(), 100 ether);
        assertEq(address(ethFarm).balance, 100 ether);
        assertEq(treasury.availableFees(address(0)), 0);
        assertEq(address(treasury).balance, 0);
        assertEq(weth.balance, 0);
    }

    function testWrappingFailureAlsoRollsBack() public {
        RejectETH beneficiary = new RejectETH();
        _depositETH(alice, 100 ether, alice);
        vm.etch(weth, address(new RevertingWETH()).code);
        vm.prank(alice);
        vm.expectRevert();
        ethFarm.withdraw(100 ether, payable(address(beneficiary)), 0);
        assertEq(ethFarm.sharesOf(alice), 100 ether);
        assertEq(treasury.availableFees(address(0)), 0);
    }

    function testNativeCallbackCannotReenterWithdrawal() public {
        ReenterETH beneficiary = new ReenterETH(ethFarm);
        _depositETH(alice, 100 ether, address(beneficiary));
        beneficiary.exit();
        assertTrue(beneficiary.blocked());
        assertEq(address(beneficiary).balance, 85 ether);
        assertEq(ethFarm.totalShares(), 0);
        assertEq(treasury.availableFees(address(0)), 15 ether);
    }

    function testForcedETHNeverBacksSharesOrRewards() public {
        _depositETH(alice, 10 ether, alice);
        vm.deal(address(ethFarm), 17 ether);
        assertEq(ethFarm.accountedAssets(), 10 ether);
        assertEq(ethFarm.previewDeposit(10 ether), 10 ether);
        assertEq(ethFarm.excessBalance(address(0)), 7 ether);
        vm.startPrank(owner);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        ethFarm.recoverExcess(address(0), payable(owner), 7 ether + 1);
        ethFarm.recoverExcess(address(0), payable(owner), 7 ether);
        vm.stopPrank();
        vm.prank(alice);
        ethFarm.withdraw(10 ether, payable(alice), 8.5 ether);
        assertEq(address(ethFarm).balance, 0);
    }

    function testDirectSendRejectedDepositSlippageAndZeroDeposit() public {
        vm.prank(alice);
        (bool ok,) = address(ethFarm).call{value: 1 ether}("");
        assertFalse(ok);
        vm.startPrank(alice);
        vm.expectRevert(RewardLedger.InvalidAmount.selector);
        ethFarm.deposit(alice, 0);
        vm.expectRevert(Farm.Slippage.selector);
        ethFarm.deposit{value: 1 ether}(alice, 1 ether + 1);
        vm.stopPrank();
        assertEq(ethFarm.totalShares(), 0);
        assertEq(address(ethFarm).balance, 0);
    }

    function testNativePrincipalAndBloomRewardsRemainSeparate() public {
        _depositETH(alice, 100 ether, alice);
        vm.startPrank(owner);
        bloom.approve(address(ethFarm), 100 ether);
        ethFarm.fundRewards(100 ether);
        ethFarm.configureEpoch(100 ether, 1);
        ethFarm.startEpoch();
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        ethFarm.withdraw(100 ether, payable(alice), 85 ether);
        assertEq(ethFarm.pendingRewards(alice), 100 ether);
        vm.prank(alice);
        ethFarm.claimRewards(alice);
        assertEq(address(ethFarm).balance, 0);
        assertEq(bloom.balanceOf(address(ethFarm)), 0);
        _assertLedger(ethFarm);
    }
}
