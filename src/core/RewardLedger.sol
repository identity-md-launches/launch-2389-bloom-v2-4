// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Managed} from "./Managed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Each farm owns its own funded, nontransferable-share reward ledger.
abstract contract RewardLedger is Managed, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_PRECISION = 1e36;
    uint256 public constant SECONDS_PER_DAY = 1 days;
    address public immutable rewardToken;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public rewardIndexPaid;
    mapping(address => uint256) public rewardCredit;
    mapping(address => uint256) public rewardFraction;
    uint256 public rewardPerShare;

    uint256 public unallocatedRewards;
    uint256 public scheduledRewards;
    /// @dev Conservative liability, including unresolved rounding dust, until the supply reaches zero.
    uint256 public earnedUnpaidRewards;
    /// @dev Subset of earnedUnpaidRewards, not an additional reserve.
    uint256 public totalCredits;
    uint256 public paidRewards;
    uint256 public fundedRewards;
    uint256 public recoveredRewards;
    uint256 public skippedRewards;
    uint256 public releasedRewardDust;

    uint256 public epochId;
    uint256 public epochStartedAt;
    uint256 public segmentStartedAt;
    uint256 public segmentDuration;
    uint256 public segmentBudget;
    uint256 public segmentReleased;
    bool public epochRunning;
    bool public epochConfigured;

    error InvalidAmount();
    error InvalidAddress();
    error InvalidDuration();
    error EpochState();
    error InsufficientBudget();
    error Insolvent();
    error InexactTransfer();
    error AccountingLimit();
    event RewardsFunded(address indexed funder, uint256 amount);
    event RewardsRecovered(address indexed recipient, uint256 amount);
    event EpochConfigured(uint256 amount, uint256 duration);
    event EpochStarted(uint256 indexed epochId, uint256 amount, uint256 start, uint256 end);
    event EpochContinued(uint256 indexed epochId, uint256 amount, uint256 end);
    event EpochCompleted(uint256 indexed epochId);
    event FutureRewardsCancelled(uint256 indexed epochId, uint256 returnedToReserve);
    event RewardsAccrued(uint256 amount, uint256 index);
    event EmissionsSkipped(uint256 amount);
    event RewardDustReleased(uint256 amount);
    event RewardFractionDiscarded(address indexed user, uint256 fraction);
    event RewardClaimed(address indexed user, address indexed recipient, uint256 amount);

    constructor(address owner_, address rewardToken_) Managed(owner_) {
        if (rewardToken_ == address(0)) revert InvalidAddress();
        rewardToken = rewardToken_;
    }

    function rewardReserve() public view returns (uint256) {
        return unallocatedRewards + scheduledRewards + earnedUnpaidRewards;
    }

    /// @notice Funding never configures, starts or accelerates an epoch.
    function fundRewards(uint256 amount) external withPower(REWARDS) nonReentrant returns (uint256 received) {
        _requireActive();
        _updateRewards();
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(rewardToken).balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InvalidAmount();
        fundedRewards += received;
        unallocatedRewards += received;
        _assertSolvent();
        emit RewardsFunded(msg.sender, received);
    }

    /// @notice Reserve an amount without starting the clock. Only valid while no epoch is running.
    function configureEpoch(uint256 amount, uint256 durationDays) external withPower(REWARDS) nonReentrant {
        _requireActive();
        _updateRewards();
        if (epochRunning) revert EpochState();
        _reschedule(amount, durationDays);
        epochConfigured = true;
        emit EpochConfigured(amount, segmentDuration);
    }

    function startEpoch() external withPower(REWARDS) nonReentrant {
        _requireCanStart();
        if (epochRunning || !epochConfigured) revert EpochState();
        _startEpoch();
        _assertSolvent();
    }

    /// @notice Explicitly start a new epoch, preserving all accrued claims. Only future funds move.
    function restartEpoch(uint256 amount, uint256 durationDays) external withPower(REWARDS) nonReentrant {
        _requireCanStart();
        _updateRewards();
        _reschedule(amount, durationDays);
        _startEpoch();
        _assertSolvent();
    }

    /// @notice Keep the epoch ID and accrued history; replace ONLY its remaining budget and duration.
    /// @dev Increasing amount or reducing remainingDays is the rate-boost operation.
    function continueEpoch(uint256 amount, uint256 remainingDays) external withPower(REWARDS) nonReentrant {
        _requireActive();
        _updateRewards();
        if (!epochRunning) revert EpochState();
        _reschedule(amount, remainingDays);
        segmentStartedAt = block.timestamp;
        emit EpochContinued(epochId, amount, epochEnd());
    }

    /// @notice Stop future emissions or cancel a pending configuration without touching accrued claims.
    function cancelFutureRewards() external withPower(REWARDS) nonReentrant {
        _updateRewards();
        uint256 returned = scheduledRewards;
        unallocatedRewards += returned;
        scheduledRewards = 0;
        epochRunning = false;
        epochConfigured = false;
        segmentBudget = 0;
        segmentReleased = 0;
        segmentStartedAt = block.timestamp;
        segmentDuration = 0;
        emit FutureRewardsCancelled(epochId, returned);
    }

    function _reschedule(uint256 amount, uint256 durationDays) private {
        if (amount == 0) revert InvalidAmount();
        if (durationDays == 0 || durationDays > type(uint256).max / SECONDS_PER_DAY) {
            revert InvalidDuration();
        }
        uint256 duration = durationDays * SECONDS_PER_DAY;
        if (duration > type(uint256).max - block.timestamp) revert InvalidDuration();
        uint256 available = unallocatedRewards + scheduledRewards;
        if (amount > available) revert InsufficientBudget();
        // A later exit may leave just one share quantum. Reserve sufficient index headroom even then.
        if (amount > (type(uint256).max - rewardPerShare) / REWARD_PRECISION) revert AccountingLimit();
        unallocatedRewards = available - amount;
        scheduledRewards = amount;
        segmentBudget = amount;
        segmentDuration = duration;
        segmentReleased = 0;
        _assertSolvent();
    }

    function _startEpoch() private {
        epochId++;
        epochStartedAt = block.timestamp;
        segmentStartedAt = block.timestamp;
        epochRunning = true;
        epochConfigured = false;
        emit EpochStarted(epochId, segmentBudget, block.timestamp, epochEnd());
    }

    /// @notice End of the running/last segment; zero for a configuration that has never started.
    function epochEnd() public view returns (uint256) {
        if (epochConfigured) return 0;
        return segmentStartedAt + segmentDuration;
    }

    function checkpoint() external nonReentrant {
        _updateRewards();
    }

    function _emissionDue() internal view returns (uint256) {
        if (!epochRunning) return 0;
        uint256 elapsed = Math.min(block.timestamp - segmentStartedAt, segmentDuration);
        return Math.mulDiv(segmentBudget, elapsed, segmentDuration) - segmentReleased;
    }

    function _updateRewards() internal {
        uint256 emission = _emissionDue();
        if (emission != 0) {
            segmentReleased += emission;
            scheduledRewards -= emission;
            if (totalShares == 0) {
                unallocatedRewards += emission;
                skippedRewards += emission;
                emit EmissionsSkipped(emission);
            } else {
                rewardPerShare += Math.mulDiv(emission, REWARD_PRECISION, totalShares);
                earnedUnpaidRewards += emission;
                emit RewardsAccrued(emission, rewardPerShare);
            }
        }
        if (epochRunning && block.timestamp >= segmentStartedAt + segmentDuration) {
            epochRunning = false;
            emit EpochCompleted(epochId);
        }
    }

    function pendingRewards(address user) public view returns (uint256) {
        uint256 index = rewardPerShare;
        if (totalShares != 0) index += Math.mulDiv(_emissionDue(), REWARD_PRECISION, totalShares);
        (uint256 whole,) = _rewardDelta(user, index);
        return rewardCredit[user] + whole;
    }

    function _rewardDelta(address user, uint256 index)
        private
        view
        returns (uint256 whole, uint256 fraction)
    {
        uint256 delta = index - rewardIndexPaid[user];
        whole = Math.mulDiv(sharesOf[user], delta, REWARD_PRECISION);
        fraction = mulmod(sharesOf[user], delta, REWARD_PRECISION) + rewardFraction[user];
        whole += fraction / REWARD_PRECISION;
        fraction %= REWARD_PRECISION;
    }

    /// @dev Lazy settlement preserves every user's old index across allocation/epoch edits.
    function _settle(address user) internal {
        _updateRewards();
        (uint256 whole, uint256 fraction) = _rewardDelta(user, rewardPerShare);
        rewardCredit[user] += whole;
        totalCredits += whole;
        rewardFraction[user] = fraction;
        rewardIndexPaid[user] = rewardPerShare;
    }

    function _afterShareBurn(address user) internal {
        if (sharesOf[user] == 0 && rewardFraction[user] != 0) {
            emit RewardFractionDiscarded(user, rewardFraction[user]);
            rewardFraction[user] = 0;
        }
        if (totalShares == 0) {
            // Every former holder settled before its final burn. Integer credits remain fully backed.
            uint256 dust = earnedUnpaidRewards - totalCredits;
            earnedUnpaidRewards = totalCredits;
            unallocatedRewards += dust;
            releasedRewardDust += dust;
            if (dust != 0) emit RewardDustReleased(dust);
        }
    }

    function claimRewards(address recipient) external nonReentrant returns (uint256 amount) {
        _validRecipient(recipient);
        _settle(msg.sender);
        amount = rewardCredit[msg.sender];
        if (amount == 0) revert InvalidAmount();
        rewardCredit[msg.sender] = 0;
        totalCredits -= amount;
        earnedUnpaidRewards -= amount;
        paidRewards += amount;
        _sendExact(rewardToken, recipient, amount);
        _assertSolvent();
        emit RewardClaimed(msg.sender, recipient, amount);
    }

    /// @notice Only genuinely free funding is recoverable; scheduled and earned funds are excluded.
    function recoverUnallocatedRewards(address recipient, uint256 amount)
        external
        withPower(RECOVERY)
        nonReentrant
    {
        _validRecipient(recipient);
        _updateRewards();
        if (amount == 0 || amount > unallocatedRewards) revert InsufficientBudget();
        unallocatedRewards -= amount;
        recoveredRewards += amount;
        _sendExact(rewardToken, recipient, amount);
        _assertSolvent();
        emit RewardsRecovered(recipient, amount);
    }

    function _sendExact(address token, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeSelf = IERC20(token).balanceOf(address(this));
        uint256 beforeRecipient = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        if (
            beforeSelf - IERC20(token).balanceOf(address(this)) != amount
                || IERC20(token).balanceOf(recipient) - beforeRecipient != amount
        ) revert InexactTransfer();
    }

    function _validRecipient(address recipient) internal view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
    }

    function _requireActive() internal view virtual;
    function _requireCanStart() internal view virtual;
    function _assertSolvent() internal view virtual;
}
