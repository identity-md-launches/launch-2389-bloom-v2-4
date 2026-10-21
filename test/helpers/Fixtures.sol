// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BloomFactory} from "../../src/BloomFactory.sol";
import {BloomTreasury} from "../../src/BloomTreasury.sol";
import {StakedBLOOM} from "../../src/StakedBLOOM.sol";
import {StakedSIMD} from "../../src/StakedSIMD.sol";
import {StakedETH} from "../../src/StakedETH.sol";
import {ERC20Farm} from "../../src/core/ERC20Farm.sol";
import {Farm} from "../../src/core/Farm.sol";
import {RewardLedger} from "../../src/core/RewardLedger.sol";
import {MainnetAssets} from "../../src/MainnetAssets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockToken is ERC20 {
    uint8 private immutable _decimals;
    uint256 public feeBps;
    bool public failTransfers;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;

    constructor(uint8 d) ERC20("Test asset", "TEST") {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function setFail(bool fail) external {
        failTransfers = fail;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!failTransfers, "TOKEN_FAILURE");
        if (from != address(0) && to != address(0)) {
            if (callbackTarget != address(0)) {
                (callbackSucceeded,) = callbackTarget.call(callbackData);
            }
            uint256 fee = value * feeBps / 10_000;
            if (fee != 0) super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

abstract contract FarmFixture is Test {
    address internal owner = address(0xA11CE);
    address internal alice = address(0xB01);
    address internal bob = address(0xB02);
    address internal carol = address(0xB03);
    BloomFactory internal registry;
    BloomTreasury internal treasury;
    MockToken internal bloom;
    StakedBLOOM internal farm;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(100);
        bloom = new MockToken(18);
        treasury = new BloomTreasury(owner);
        registry = new BloomFactory(owner, address(treasury));
        vm.startPrank(owner);
        treasury.bindRegistry(address(registry));
        registry.bindBloom(address(bloom));
        registry.whitelistAsset(address(bloom), true);
        vm.stopPrank();
        farm = new StakedBLOOM(owner, address(registry), address(treasury), address(bloom), 18);
        _activate(farm);
        bloom.mint(owner, 1e30);
        bloom.mint(alice, 1e30);
        bloom.mint(bob, 1e30);
        bloom.mint(carol, 1e30);
        vm.prank(owner);
        bloom.approve(address(farm), type(uint256).max);
        vm.prank(alice);
        bloom.approve(address(farm), type(uint256).max);
        vm.prank(bob);
        bloom.approve(address(farm), type(uint256).max);
        vm.prank(carol);
        bloom.approve(address(farm), type(uint256).max);
    }

    function _activate(Farm target) internal {
        vm.startPrank(owner);
        registry.whitelistAsset(target.asset(), true);
        registry.registerFarm(address(target));
        target.activate();
        target.setDepositsPaused(false);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.prank(user);
        return farm.deposit(amount, user, 1);
    }

    function _fund(uint256 amount) internal {
        vm.prank(owner);
        farm.fundRewards(amount);
    }

    function _start(uint256 amount, uint256 days_) internal {
        vm.startPrank(owner);
        farm.configureEpoch(amount, days_);
        farm.startEpoch();
        vm.stopPrank();
    }

    function _withdrawAll(address user) internal {
        uint256 shares = farm.sharesOf(user);
        vm.prank(user);
        farm.withdraw(shares, payable(user), 0);
    }

    function _assertLedger(Farm f) internal view {
        assertEq(f.fundedRewards(), f.rewardReserve() + f.paidRewards() + f.recoveredRewards());
        assertLe(f.totalCredits(), f.earnedUnpaidRewards());
        assertGe(IERC20(f.rewardToken()).balanceOf(address(f)), f.protectedBalance(f.rewardToken()));
        if (f.asset() == address(0)) assertGe(address(f).balance, f.accountedAssets());
        else assertGe(IERC20(f.asset()).balanceOf(address(f)), f.protectedBalance(f.asset()));
    }
}
