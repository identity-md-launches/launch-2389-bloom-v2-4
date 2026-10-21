// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NetworkFixture} from "./helpers/NetworkFixture.sol";
import {MockToken} from "./helpers/Fixtures.sol";
import {Farm} from "src/core/Farm.sol";
import {ERC20Farm} from "src/core/ERC20Farm.sol";
import {StakedETH} from "src/StakedETH.sol";
import {StakedSIMD} from "src/StakedSIMD.sol";
import {BloomFactory} from "src/BloomFactory.sol";
import {BloomTreasury} from "src/BloomTreasury.sol";
import {MainnetAssets} from "src/MainnetAssets.sol";
import {IStakedIMD} from "src/interfaces/IBloom.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev All custody ghosts come from observed transfers, not farm accounting getters.
contract NetworkHandler is Test {
    struct Flow {
        uint256 deposited;
        uint256 withdrawn;
        uint256 funded;
        uint256 claimed;
        uint256 recovered;
        uint256 assetDonations;
        uint256 rewardDonations;
        uint256 treasuryDonations;
        uint256 spent;
    }

    struct ExitSnapshot {
        uint256 owned;
        uint256 burn;
        uint256 quote;
        uint256 recipientAssets;
        uint256 recipientWETH;
        uint256 pending;
    }

    Farm[3] public farms;
    address[4] public actors;
    Flow[3] public flows;
    BloomTreasury public treasury;
    BloomFactory public registry;
    MockToken public bloom;
    address public owner;
    uint256 public depositsExecuted;
    uint256 public exitsExecuted;
    uint256 public claimsExecuted;
    uint256 public fallbackPaid;

    constructor(
        Farm[3] memory farms_,
        address[4] memory actors_,
        BloomTreasury treasury_,
        BloomFactory registry_,
        MockToken bloom_,
        address owner_
    ) {
        farms = farms_;
        actors = actors_;
        treasury = treasury_;
        registry = registry_;
        bloom = bloom_;
        owner = owner_;
    }

    function _balance(address token, address account) internal view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    function _open(Farm f) internal view returns (bool) {
        return !f.depositsPaused() && registry.isAssetWhitelisted(f.asset());
    }

    function deposit(uint256 which, uint256 who, uint256 beneficiary, uint256 raw) public {
        which %= 3;
        Farm f = farms[which];
        if (!_open(f)) return;
        address payer = actors[who % 4];
        address receiver = actors[beneficiary % 4];
        uint256 amount = bound(raw, 1, which == 1 ? 1e28 : 1e22);
        uint256 quote = f.previewDeposit(amount);
        uint256 beforeCustody = _balance(f.asset(), address(f));
        uint256 beforeShares = f.sharesOf(receiver);
        uint256 beforeClaim = f.pendingRewards(receiver);
        vm.prank(payer);
        if (quote == 0) vm.expectRevert(Farm.ZeroShares.selector);
        uint256 minted;
        if (which == 2) minted = StakedETH(address(f)).deposit{value: amount}(receiver, quote);
        else minted = ERC20Farm(address(f)).deposit(amount, receiver, quote);
        if (quote == 0) {
            assertEq(_balance(f.asset(), address(f)), beforeCustody, "zero mint took assets");
            assertEq(f.sharesOf(receiver), beforeShares);
            return;
        }
        assertEq(minted, quote, "deposit preview mismatch");
        assertEq(f.sharesOf(receiver) - beforeShares, minted, "wrong beneficiary");
        assertEq(f.pendingRewards(receiver), beforeClaim, "new shares earned past rewards");
        flows[which].deposited += _balance(f.asset(), address(f)) - beforeCustody;
        depositsExecuted++;
    }

    function depositIMD(uint256 who, uint256 beneficiary, uint256 raw) external {
        Farm f = farms[1];
        if (!_open(f)) return;
        address payer = actors[who % 4];
        address receiver = actors[beneficiary % 4];
        // At least one IMD; exact conversion dust and zero mints have separate deterministic tests.
        uint256 amount = bound(raw, 1 ether, 1e22);
        uint256 beforeCustody = IERC20(MainnetAssets.SIMD).balanceOf(address(f));
        uint256 beforeClaim = f.pendingRewards(receiver);
        uint256 converted = IStakedIMD(MainnetAssets.SIMD).convertToShares(amount);
        uint256 quote = f.previewDeposit(converted);
        vm.prank(payer);
        uint256 minted = StakedSIMD(address(f)).depositIMD(amount, receiver, converted, quote);
        uint256 received = IERC20(MainnetAssets.SIMD).balanceOf(address(f)) - beforeCustody;
        assertEq(received, converted, "official conversion receipt");
        assertEq(minted, quote);
        assertEq(f.pendingRewards(receiver), beforeClaim);
        assertEq(IERC20(MainnetAssets.IMD).allowance(address(f), MainnetAssets.SIMD), 0);
        flows[1].deposited += received;
        depositsExecuted++;
    }

    function withdraw(uint256 which, uint256 who, uint256 beneficiary, uint256 raw, bool full) public {
        which %= 3;
        Farm f = farms[which];
        address user = actors[who % 4];
        address receiver = actors[beneficiary % 4];
        ExitSnapshot memory s;
        s.owned = f.sharesOf(user);
        if (s.owned == 0) return;
        s.burn = full ? s.owned : bound(raw, 1, s.owned);
        (, s.quote,,) = f.previewRedeem(s.burn);
        s.recipientAssets = _balance(f.asset(), receiver);
        s.recipientWETH = IERC20(MainnetAssets.WETH).balanceOf(receiver);
        s.pending = f.pendingRewards(user);
        vm.prank(user);
        uint256 result = f.withdraw(s.burn, payable(receiver), s.quote);
        uint256 paid = _balance(f.asset(), receiver) - s.recipientAssets;
        if (which == 2) {
            uint256 wrapped = IERC20(MainnetAssets.WETH).balanceOf(receiver) - s.recipientWETH;
            paid += wrapped;
            fallbackPaid += wrapped;
        }
        assertEq(result, s.quote, "redemption preview mismatch");
        assertEq(paid, s.quote, "beneficiary payout");
        assertEq(f.sharesOf(user), s.owned - s.burn);
        assertEq(f.pendingRewards(user), s.pending, "burn lost accrued rewards");
        flows[which].withdrawn += paid;
        exitsExecuted++;
    }

    function claim(uint256 which, uint256 who, uint256 beneficiary) public {
        which %= 3;
        Farm f = farms[which];
        address user = actors[who % 4];
        address receiver = actors[beneficiary % 4];
        uint256 expected = f.pendingRewards(user);
        if (expected == 0) return;
        uint256 beforeBalance = bloom.balanceOf(receiver);
        uint256 beforeFees = treasury.receivedFees(f.asset());
        uint256 beforeAssets = f.accountedAssets();
        uint256 beforeShares = f.sharesOf(user);
        vm.prank(user);
        assertEq(f.claimRewards(receiver), expected);
        uint256 paid = bloom.balanceOf(receiver) - beforeBalance;
        assertEq(paid, expected, "claim fee or short payment");
        assertEq(f.pendingRewards(user), 0, "double claim");
        assertEq(treasury.receivedFees(f.asset()), beforeFees);
        assertEq(f.accountedAssets(), beforeAssets);
        assertEq(f.sharesOf(user), beforeShares);
        flows[which].claimed += paid;
        claimsExecuted++;
    }

    function fund(uint256 which, uint256 raw) public {
        which %= 3;
        Farm f = farms[which];
        uint256 amount = bound(raw, 1, 1e23);
        uint256 beforeBalance = bloom.balanceOf(address(f));
        uint256 id = f.epochId();
        vm.prank(owner);
        assertEq(f.fundRewards(amount), amount);
        flows[which].funded += bloom.balanceOf(address(f)) - beforeBalance;
        assertEq(f.epochId(), id, "funding started an epoch");
    }

    function elapse(uint256 raw) public {
        uint256 elapsed = bound(raw, 0, 4 days);
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + elapsed / 12 + 1);
    }

    function editEpoch(uint256 which, uint256 raw, uint256 daysRaw, uint256 mode) public {
        Farm f = farms[which % 3];
        f.checkpoint();
        uint256 available = f.unallocatedRewards() + f.scheduledRewards();
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        uint256 duration = bound(daysRaw, 1, 30);
        uint256 id = f.epochId();
        uint256 started = f.epochStartedAt();
        uint256[4] memory earned;
        for (uint256 i; i < 4; ++i) {
            earned[i] = f.pendingRewards(actors[i]);
        }
        vm.startPrank(owner);
        if (mode % 3 == 0 && f.epochRunning()) {
            f.continueEpoch(amount, duration);
            assertEq(f.epochId(), id);
            assertEq(f.epochStartedAt(), started);
        } else if (mode % 3 == 1 && !f.epochRunning()) {
            f.configureEpoch(amount, duration);
            assertEq(f.epochId(), id);
            assertFalse(f.epochRunning());
            assertEq(f.epochEnd(), 0);
        } else if (_open(f)) {
            f.restartEpoch(amount, duration);
            assertEq(f.epochId(), id + 1);
        }
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            assertEq(f.pendingRewards(actors[i]), earned[i], "epoch erased claim");
        }
    }

    function startConfigured(uint256 which) external {
        Farm f = farms[which % 3];
        if (!_open(f) || f.epochRunning() || !f.epochConfigured()) return;
        vm.prank(owner);
        f.startEpoch();
    }

    function cancel(uint256 which) public {
        Farm f = farms[which % 3];
        uint256[4] memory earned;
        for (uint256 i; i < 4; ++i) {
            earned[i] = f.pendingRewards(actors[i]);
        }
        vm.prank(owner);
        f.cancelFutureRewards();
        for (uint256 i; i < 4; ++i) {
            assertEq(f.pendingRewards(actors[i]), earned[i]);
        }
    }

    function recoverFree(uint256 which, uint256 raw) public {
        which %= 3;
        Farm f = farms[which];
        f.checkpoint();
        uint256 available = f.unallocatedRewards();
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        uint256 beforeBalance = bloom.balanceOf(owner);
        vm.prank(owner);
        f.recoverUnallocatedRewards(owner, amount);
        flows[which].recovered += bloom.balanceOf(owner) - beforeBalance;
    }

    function controls(uint256 which, bool paused, bool whitelisted) public {
        Farm f = farms[which % 3];
        vm.startPrank(owner);
        f.setDepositsPaused(paused);
        registry.whitelistAsset(f.asset(), whitelisted);
        vm.stopPrank();
    }

    function donate(uint256 which, uint256 raw, bool rewards, bool toTreasury) external {
        which %= 3;
        Farm f = farms[which];
        // Treasury donations are always denominated in the corresponding underlying.
        address token = rewards && !toTreasury ? address(bloom) : f.asset();
        address recipient = toTreasury ? address(treasury) : address(f);
        uint256 amount = bound(raw, 1, token == MainnetAssets.SIMD ? 1e27 : 1e21);
        uint256 beforeQuote = f.previewDeposit(1e18);
        if (token == address(bloom)) {
            bloom.mint(recipient, amount);
        } else if (token == address(0)) {
            vm.deal(recipient, recipient.balance + amount);
        } else {
            vm.prank(actors[0]);
            IERC20(token).transfer(recipient, amount);
        }
        if (toTreasury) flows[which].treasuryDonations += amount;
        else if (rewards) flows[which].rewardDonations += amount;
        else flows[which].assetDonations += amount;
        assertEq(f.previewDeposit(1e18), beforeQuote, "donation inflated shares");
    }

    function recoverDonation(uint256 which, uint256 raw, bool rewards) external {
        which %= 3;
        Farm f = farms[which];
        uint256 available = rewards ? flows[which].rewardDonations : flows[which].assetDonations;
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        address token = rewards ? address(bloom) : f.asset();
        uint256 beforeBalance = _balance(token, owner);
        vm.prank(owner);
        f.recoverExcess(token, payable(owner), amount);
        assertEq(_balance(token, owner) - beforeBalance, amount);
        if (rewards) flows[which].rewardDonations -= amount;
        else flows[which].assetDonations -= amount;
    }

    function spend(uint256 which, uint256 raw) public {
        which %= 3;
        address token = farms[which].asset();
        uint256 available = treasury.availableFees(token);
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        uint256 beforeBalance = _balance(token, owner);
        vm.prank(owner);
        treasury.spendFees(token, payable(owner), amount);
        flows[which].spent += _balance(token, owner) - beforeBalance;
    }

    function vaultYield(uint256 raw) external {
        Farm f = farms[1];
        uint256 backing = f.accountedAssets();
        uint256 supply = f.totalShares();
        uint256 custody = IERC20(MainnetAssets.SIMD).balanceOf(address(f));
        uint256 value = IStakedIMD(MainnetAssets.SIMD).convertToAssets(custody);
        uint256 amount = bound(raw, 1, 1e23);
        vm.prank(actors[0]);
        IERC20(MainnetAssets.IMD).transfer(MainnetAssets.SIMD, amount);
        assertEq(f.accountedAssets(), backing, "price yield changed quantity backing");
        assertEq(f.totalShares(), supply);
        assertEq(IERC20(MainnetAssets.SIMD).balanceOf(address(f)), custody);
        assertGe(IStakedIMD(MainnetAssets.SIMD).convertToAssets(custody), value);
    }

    /// @dev A complete position cycle with no intervening withdrawal by anyone else.
    function roundTrip(uint256 which, uint256 who, uint256 raw) external {
        which %= 3;
        Farm f = farms[which];
        if (!_open(f)) return;
        address actor = actors[who % 4];
        uint256 amount = bound(raw, 1e12, which == 1 ? 1e26 : 1e22);
        uint256 beforeShares = f.sharesOf(actor);
        uint256 beforeBalance = _balance(f.asset(), actor);
        uint256 beforeWrapped = IERC20(MainnetAssets.WETH).balanceOf(actor);
        deposit(which, who, who, amount);
        uint256 minted = f.sharesOf(actor) - beforeShares;
        if (minted == 0) return;
        withdraw(which, who, who, minted, false);
        assertEq(f.sharesOf(actor), beforeShares);
        uint256 afterBalance = _balance(f.asset(), actor);
        if (which == 2) afterBalance += IERC20(MainnetAssets.WETH).balanceOf(actor) - beforeWrapped;
        assertLe(afterBalance, beforeBalance, "profitable isolated round trip");
    }

    function assertAccounting() public view {
        for (uint256 n; n < 3; ++n) {
            Farm f = farms[n];
            Flow memory g = flows[n];
            address token = f.asset();
            uint256 fees = treasury.receivedFees(token);
            assertEq(g.deposited, f.accountedAssets() + g.withdrawn + fees, "principal conservation");
            assertEq(f.cumulativeTreasuryFees(), fees, "fee collected twice or lost");
            assertEq(f.fundedRewards(), g.funded, "funding ghost");
            assertEq(f.paidRewards(), g.claimed, "claim ghost");
            assertEq(f.recoveredRewards(), g.recovered, "recovery ghost");
            assertEq(g.funded, f.rewardReserve() + g.claimed + g.recovered, "reward conservation");

            uint256 sameTokenReserve = n == 0 ? f.rewardReserve() + g.rewardDonations : 0;
            assertEq(_balance(token, address(f)), f.accountedAssets() + g.assetDonations + sameTokenReserve);
            if (n != 0) assertEq(bloom.balanceOf(address(f)), f.rewardReserve() + g.rewardDonations);
            assertEq(f.excessBalance(token), g.assetDonations + (n == 0 ? g.rewardDonations : 0));
            assertEq(_balance(token, address(treasury)) + g.spent, fees + g.treasuryDonations);
            assertEq(treasury.spentFees(token), g.spent);
            assertEq(treasury.availableFees(token) + g.spent, fees);

            uint256 shares;
            uint256 credits;
            uint256 pending;
            for (uint256 i; i < 4; ++i) {
                shares += f.sharesOf(actors[i]);
                credits += f.rewardCredit(actors[i]);
                pending += f.pendingRewards(actors[i]);
                assertLt(f.rewardFraction(actors[i]), f.REWARD_PRECISION());
                assertLe(f.rewardIndexPaid(actors[i]), f.rewardPerShare());
            }
            assertEq(shares, f.totalShares(), "share supply");
            assertEq(credits, f.totalCredits(), "credit supply");
            assertLe(credits, f.earnedUnpaidRewards());
            assertLe(pending, f.earnedUnpaidRewards() + f.scheduledRewards());
            if (shares == 0) {
                assertEq(f.accountedAssets(), 0, "backing stranded after last exit");
                assertEq(f.earnedUnpaidRewards(), credits, "dust not released");
            }
            if (token != address(0)) assertEq(IERC20(token).allowance(address(f), address(treasury)), 0);
        }
        assertEq(IERC20(MainnetAssets.IMD).allowance(address(farms[1]), MainnetAssets.SIMD), 0);
        assertEq(IERC20(MainnetAssets.IMD).balanceOf(address(farms[1])), 0);
        assertEq(IERC20(MainnetAssets.WETH).balanceOf(address(farms[2])), 0, "stranded fallback WETH");
        assertEq(MainnetAssets.WETH.balance, fallbackPaid, "wrapping conservation");
    }

    /// @dev Executed after every campaign, including while deposits are disabled/delisted.
    function closeAll() external {
        for (uint256 n; n < 3; ++n) {
            controls(n, true, false);
            for (uint256 i; i < 4; ++i) {
                withdraw(n, i, i, 0, true);
            }
            cancel(n);
            for (uint256 i; i < 4; ++i) {
                claim(n, i, (i + 1) % 4);
            }
            recoverFree(n, farms[n].unallocatedRewards());
            spend(n, treasury.availableFees(farms[n].asset()));
            assertEq(farms[n].totalShares(), 0);
            assertEq(farms[n].accountedAssets(), 0);
            assertEq(farms[n].totalCredits(), 0);
            assertEq(farms[n].earnedUnpaidRewards(), 0);
            assertEq(farms[n].rewardReserve(), 0, "unpayable reward obligation");
        }
        assertAccounting();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract NetworkInvariantTest is NetworkFixture {
    NetworkHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new NetworkHandler(allFarms, actors, treasury, registry, bloom, owner);
        // Reach funded, running, multi-actor states in every campaign before random transitions.
        for (uint256 n; n < 3; ++n) {
            handler.deposit(n, 0, 0, n == 1 ? 100e24 : 100 ether);
            handler.deposit(n, 1, 1, n == 1 ? 100e24 : 100 ether);
            handler.fund(n, 1000 ether);
            handler.editEpoch(n, 1000 ether, 10, 2);
        }
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.depositIMD.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.fund.selector;
        selectors[5] = handler.elapse.selector;
        selectors[6] = handler.editEpoch.selector;
        selectors[7] = handler.startConfigured.selector;
        selectors[8] = handler.cancel.selector;
        selectors[9] = handler.recoverFree.selector;
        selectors[10] = handler.controls.selector;
        selectors[11] = handler.donate.selector;
        selectors[12] = handler.recoverDonation.selector;
        selectors[13] = handler.spend.selector;
        selectors[14] = handler.vaultYield.selector;
        selectors[15] = handler.roundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_CustodySharesFeesAndRewardsRemainConserved() public view {
        handler.assertAccounting();
        assertGe(handler.depositsExecuted(), 6, "campaign never entered funded custody");
    }

    function test_HandlerExercisesFallbackClaimsAndAllAssetRecoveryBeforeClosing() public {
        handler.elapse(1 days);
        handler.depositIMD(2, 3, 10 ether);
        handler.vaultYield(100 ether);
        handler.withdraw(2, 0, 3, 0, true);
        assertEq(handler.fallbackPaid(), 85 ether);
        handler.claim(2, 0, 1);
        assertEq(handler.claimsExecuted(), 1);
        for (uint256 n; n < 3; ++n) {
            handler.donate(n, 100, false, false);
            handler.donate(n, 200, true, false);
            handler.donate(n, 300, false, true);
            handler.recoverDonation(n, 100, false);
            handler.recoverDonation(n, 200, true);
            handler.cancel(n);
            handler.editEpoch(n, 100, 1, 1);
            handler.startConfigured(n);
        }
        handler.assertAccounting();
        handler.closeAll();
        assertGe(handler.exitsExecuted(), 7);
        assertGt(handler.claimsExecuted(), 1);
    }

    function afterInvariant() public {
        handler.closeAll();
    }
}
