// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Managed} from "./core/Managed.sol";
import {IBloomRegistry} from "./interfaces/IBloom.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Spendable balances are fees actually received through the registered-farm entry points.
contract BloomTreasury is Managed, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public registry;
    mapping(address asset => uint256) public receivedFees;
    mapping(address asset => uint256) public spentFees;

    error InvalidAddress();
    error AlreadyBound();
    error InvalidRegistry();
    error NotFarm();
    error InvalidAmount();
    error TransferFailed();
    event RegistryBound(address indexed registry);
    event FeeReceived(address indexed farm, address indexed asset, uint256 amount);
    event FeesSpent(address indexed asset, address indexed recipient, uint256 amount);

    constructor(address owner_) Managed(owner_) {}

    /// @notice Owner-only, one-time binding; constructors have no external dependencies.
    function bindRegistry(address registry_) external withPower(CONFIG) {
        if (registry != address(0)) revert AlreadyBound();
        if (registry_.code.length == 0) revert InvalidRegistry();
        if (
            IBloomRegistry(registry_).owner() != owner()
                || IBloomRegistry(registry_).treasury() != address(this)
        ) {
            revert InvalidRegistry();
        }
        registry = registry_;
        emit RegistryBound(registry_);
    }

    modifier onlyFarm() {
        if (registry == address(0) || !IBloomRegistry(registry).isFarm(msg.sender)) revert NotFarm();
        _;
    }

    function receiveTokenFee(address token, uint256 amount)
        external
        onlyFarm
        nonReentrant
        returns (uint256 received)
    {
        if (token != IBloomFarmAsset(msg.sender).asset()) revert InvalidAddress();
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - beforeBalance;
        if (received != amount || amount == 0) revert InvalidAmount();
        receivedFees[token] += received;
        emit FeeReceived(msg.sender, token, received);
    }

    function receiveNativeFee() external payable onlyFarm nonReentrant {
        if (IBloomFarmAsset(msg.sender).asset() != address(0) || msg.value == 0) revert InvalidAmount();
        receivedFees[address(0)] += msg.value;
        emit FeeReceived(msg.sender, address(0), msg.value);
    }

    function availableFees(address token) public view returns (uint256) {
        return receivedFees[token] - spentFees[token];
    }

    function spendFees(address token, address payable recipient, uint256 amount)
        external
        withPower(SPEND)
        nonReentrant
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        if (amount == 0 || amount > availableFees(token)) revert InvalidAmount();
        spentFees[token] += amount;
        if (token == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            uint256 beforeBalance = IERC20(token).balanceOf(address(this));
            uint256 beforeRecipient = IERC20(token).balanceOf(recipient);
            IERC20(token).safeTransfer(recipient, amount);
            if (
                beforeBalance - IERC20(token).balanceOf(address(this)) != amount
                    || IERC20(token).balanceOf(recipient) - beforeRecipient != amount
            ) revert TransferFailed();
        }
        emit FeesSpent(token, recipient, amount);
    }
}

interface IBloomFarmAsset {
    function asset() external view returns (address);
}
