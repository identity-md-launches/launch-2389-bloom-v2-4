// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FarmFixture, StakedBLOOM, BloomTreasury, MockToken} from "./helpers/Fixtures.sol";

contract FarmHandler is Test {
    StakedBLOOM public farm;
    BloomTreasury public treasury;
    MockToken public token;
    address public owner;
    address[3] public users;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public donated;

    constructor(StakedBLOOM f, BloomTreasury t, MockToken token_, address owner_, address[3] memory users_) {
        farm = f;
        treasury = t;
        token = token_;
        owner = owner_;
        users = users_;
    }

    function deposit(uint256 who, uint96 raw) external {
        if (farm.depositsPaused()) return;
        address user = users[who % 3];
        uint256 amount = bound(uint256(raw), 2, 1e22);
        if (farm.previewDeposit(amount) == 0) return;
        vm.prank(user);
        farm.deposit(amount, user, 1);
        deposited += amount;
    }

    function withdraw(uint256 who, uint256 raw) external {
        address user = users[who % 3];
        uint256 shares = farm.sharesOf(user);
        if (shares == 0) return;
        shares = bound(raw, 1, shares);
        uint256 beforeBalance = token.balanceOf(user);
        vm.prank(user);
        farm.withdraw(shares, payable(user), 0);
        withdrawn += token.balanceOf(user) - beforeBalance;
    }

    function claim(uint256 who) external {
        address user = users[who % 3];
        if (farm.pendingRewards(user) == 0) return;
        vm.prank(user);
        farm.claimRewards(user);
    }

    function fund(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1, 1e22);
        vm.prank(owner);
        farm.fundRewards(amount);
    }

    function elapse(uint32 raw) external {
        vm.warp(block.timestamp + bound(uint256(raw), 0, 3 days));
    }

    function editEpoch(uint96 raw, uint8 days_, bool continue_) external {
        farm.checkpoint();
        uint256 available = farm.unallocatedRewards() + farm.scheduledRewards();
        if (available == 0) return;
        uint256 amount = bound(uint256(raw), 1, available);
        uint256 duration = bound(uint256(days_), 1, 30);
        if (continue_ && farm.epochRunning()) {
            vm.prank(owner);
            farm.continueEpoch(amount, duration);
        } else if (!farm.depositsPaused()) {
            vm.prank(owner);
            farm.restartEpoch(amount, duration);
        }
    }

    function cancel() external {
        vm.prank(owner);
        farm.cancelFutureRewards();
    }

    function recover(uint96 raw) external {
        farm.checkpoint();
        uint256 free = farm.unallocatedRewards();
        if (free == 0) return;
        vm.prank(owner);
        farm.recoverUnallocatedRewards(owner, bound(uint256(raw), 1, free));
    }

    function donate(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 0, 1e22);
        token.mint(address(farm), amount);
        donated += amount;
    }

    function pause(bool paused) external {
        vm.prank(owner);
        farm.setDepositsPaused(paused);
    }
}

contract FarmInvariantTest is FarmFixture {
    FarmHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new FarmHandler(farm, treasury, bloom, owner, [alice, bob, carol]);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.fund.selector;
        selectors[4] = handler.elapse.selector;
        selectors[5] = handler.editEpoch.selector;
        selectors[6] = handler.cancel.selector;
        selectors[7] = handler.recover.selector;
        selectors[8] = handler.donate.selector;
        selectors[9] = handler.pause.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantPrincipalAndFeeConservation() public view {
        assertEq(
            handler.deposited(),
            farm.accountedAssets() + handler.withdrawn() + treasury.receivedFees(address(bloom))
        );
        assertEq(farm.sharesOf(alice) + farm.sharesOf(bob) + farm.sharesOf(carol), farm.totalShares());
        if (farm.totalShares() == 0) assertEq(farm.accountedAssets(), 0);
        assertEq(farm.excessBalance(address(bloom)), handler.donated());
        assertEq(
            bloom.balanceOf(address(farm)), farm.accountedAssets() + farm.rewardReserve() + handler.donated()
        );
    }

    function invariantRewardSolvencyAndCredits() public view {
        _assertLedger(farm);
        assertEq(
            farm.totalCredits(), farm.rewardCredit(alice) + farm.rewardCredit(bob) + farm.rewardCredit(carol)
        );
        uint256 pending = farm.pendingRewards(alice) + farm.pendingRewards(bob) + farm.pendingRewards(carol);
        assertLe(pending, farm.earnedUnpaidRewards() + farm.scheduledRewards());
        assertEq(bloom.balanceOf(address(treasury)), treasury.receivedFees(address(bloom)));
        assertEq(bloom.allowance(address(farm), address(treasury)), 0);
    }
}
