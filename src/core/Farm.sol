// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RewardLedger} from "./RewardLedger.sol";
import {IBloomRegistry, IFeeTreasury} from "../interfaces/IBloom.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract Farm is RewardLedger {
    using SafeERC20 for IERC20;

    uint8 public constant decimals = 18;
    uint256 public constant USER_BPS = 8500;
    uint256 public constant TREASURY_BPS = 100;
    uint256 public constant BPS = 10_000;
    address public immutable registry;
    address public immutable treasury;
    address public immutable asset;
    uint8 public immutable assetDecimals;
    uint256 public immutable virtualAssets;
    uint256 public immutable virtualShares;
    uint256 public accountedAssets;
    uint256 public cumulativeRetainedFees;
    uint256 public cumulativeTreasuryFees;
    bool public active;
    bool public depositsPaused = true;

    error NotActive();
    error DepositsPaused();
    error InvalidDependency();
    error WrongChain();
    error AlreadyActive();
    error Slippage();
    error ZeroShares();
    error InsufficientShares();
    error NativeTransferFailed();
    event Activated(address indexed asset, address indexed rewardToken);
    event DepositsPauseSet(bool paused);
    event Deposit(address indexed caller, address indexed beneficiary, uint256 assets, uint256 shares);
    event Withdrawal(
        address indexed user,
        address indexed beneficiary,
        uint256 shares,
        uint256 grossAssets,
        uint256 userAssets
    );
    event WithdrawalFee(uint256 grossAssets, uint256 treasuryAssets, uint256 retainedAssets, bool finalExit);
    event ExcessRecovered(address indexed asset, address indexed recipient, uint256 amount);

    constructor(
        address owner_,
        address registry_,
        address treasury_,
        address rewardToken_,
        address asset_,
        uint8 assetDecimals_
    ) RewardLedger(owner_, rewardToken_) {
        if (registry_ == address(0) || treasury_ == address(0)) revert InvalidAddress();
        if (assetDecimals_ > 36) revert InvalidDependency();
        registry = registry_;
        treasury = treasury_;
        asset = asset_;
        assetDecimals = assetDecimals_;
        virtualAssets = assetDecimals_ > 18 ? 10 ** (assetDecimals_ - 18) : 1;
        virtualShares = assetDecimals_ < 18 ? 10 ** (18 - assetDecimals_) : 1;
    }

    /// @notice Explicit owner-only verification; never enables deposits or emissions.
    function activate() external withPower(CONFIG) nonReentrant {
        if (active) revert AlreadyActive();
        if (block.chainid != 1) revert WrongChain();
        IBloomRegistry r = IBloomRegistry(registry);
        if (
            !r.isFarm(address(this)) || r.farmForAsset(asset) != address(this) || r.bloom() != rewardToken
                || r.treasury() != treasury || IFeeTreasuryRegistry(treasury).registry() != registry
        ) revert InvalidDependency();
        if (rewardToken.code.length == 0 || IERC20Metadata(rewardToken).decimals() > 36) {
            revert InvalidDependency();
        }
        if (asset != address(0) && IERC20Metadata(asset).decimals() != assetDecimals) {
            revert InvalidDependency();
        }
        _verifyAsset();
        active = true;
        emit Activated(asset, rewardToken);
    }

    function setDepositsPaused(bool paused) external withPower(PAUSE) {
        if (!paused) _requireActive();
        depositsPaused = paused;
        emit DepositsPauseSet(paused);
    }

    function _requireActive() internal view override {
        if (!active) revert NotActive();
    }

    function _requireCanStart() internal view override {
        _requireDepositAllowed();
    }

    function _requireDepositAllowed() internal view {
        _requireActive();
        if (depositsPaused || !IBloomRegistry(registry).isAssetWhitelisted(asset)) revert DepositsPaused();
    }

    /// @notice Raw underlying units to 18-decimal, internal, nontransferable shares, rounded DOWN.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalShares + virtualShares, accountedAssets + virtualAssets);
    }

    /// @notice Last holder receives all residual backing in the gross redemption before fees.
    function previewRedeem(uint256 shares)
        public
        view
        returns (uint256 gross, uint256 userAssets, uint256 treasuryAssets, uint256 retained)
    {
        if (shares == 0 || shares > totalShares) return (0, 0, 0, 0);
        bool last = shares == totalShares;
        gross = last
            ? accountedAssets
            : Math.mulDiv(shares, accountedAssets + virtualAssets, totalShares + virtualShares);
        userAssets = Math.mulDiv(gross, USER_BPS, BPS);
        treasuryAssets = last ? gross - userAssets : Math.mulDiv(gross, TREASURY_BPS, BPS);
        retained = gross - userAssets - treasuryAssets;
    }

    function _mintShares(address beneficiary, uint256 assets, uint256 minSharesOut)
        internal
        returns (uint256 shares)
    {
        // Caller has settled beneficiary before any transfer/conversion.
        if (assets == 0) revert InvalidAmount();
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();
        if (shares < minSharesOut) revert Slippage();
        // Keep virtual offsets representable for every subsequent partial redemption.
        if (
            assets > type(uint256).max - virtualAssets - accountedAssets
                || shares > type(uint256).max - virtualShares - totalShares
        ) revert AccountingLimit();
        accountedAssets += assets;
        totalShares += shares;
        sharesOf[beneficiary] += shares;
        _assertSolvent();
        emit Deposit(msg.sender, beneficiary, assets, shares);
    }

    function withdraw(uint256 shares, address payable beneficiary, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 userAssets)
    {
        _validRecipient(beneficiary);
        if (shares == 0 || shares > sharesOf[msg.sender]) revert InsufficientShares();
        _settle(msg.sender);
        (uint256 gross, uint256 userAmount, uint256 fee, uint256 retained) = previewRedeem(shares);
        if (userAmount < minAssetsOut) revert Slippage();
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        accountedAssets = accountedAssets - gross + retained;
        cumulativeRetainedFees += retained;
        cumulativeTreasuryFees += fee;
        _afterShareBurn(msg.sender);
        _payFee(fee);
        _payUnderlying(beneficiary, userAmount);
        _assertSolvent();
        emit Withdrawal(msg.sender, beneficiary, shares, gross, userAmount);
        emit WithdrawalFee(gross, fee, retained, totalShares == 0);
        return userAmount;
    }

    function protectedBalance(address token) public view returns (uint256 balance) {
        if (token == asset) balance = accountedAssets;
        if (token == rewardToken) balance += rewardReserve();
    }

    function excessBalance(address token) public view returns (uint256) {
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 reserved = protectedBalance(token);
        return balance > reserved ? balance - reserved : 0;
    }

    /// @notice Donations/forced ETH are isolated; this cannot move even one unit of backing or reward reserves.
    function recoverExcess(address token, address payable recipient, uint256 amount)
        external
        withPower(RECOVERY)
        nonReentrant
    {
        _validRecipient(recipient);
        if (amount == 0 || amount > excessBalance(token)) revert InvalidAmount();
        if (token == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            _sendExact(token, recipient, amount);
        }
        _assertSolvent();
        emit ExcessRecovered(token, recipient, amount);
    }

    function _assertSolvent() internal view override {
        uint256 assetBalance =
            asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (assetBalance < protectedBalance(asset)) revert Insolvent();
        if (asset != rewardToken && IERC20(rewardToken).balanceOf(address(this)) < rewardReserve()) {
            revert Insolvent();
        }
    }

    function _payFee(uint256 amount) private {
        if (amount == 0) return;
        if (asset == address(0)) {
            IFeeTreasury(treasury).receiveNativeFee{value: amount}();
        } else {
            uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
            IERC20(asset).forceApprove(treasury, amount);
            uint256 received = IFeeTreasury(treasury).receiveTokenFee(asset, amount);
            IERC20(asset).forceApprove(treasury, 0);
            if (received != amount || beforeBalance - IERC20(asset).balanceOf(address(this)) != amount) {
                revert InexactTransfer();
            }
        }
    }

    function _verifyAsset() internal view virtual;
    function _payUnderlying(address payable beneficiary, uint256 amount) internal virtual;
}

interface IFeeTreasuryRegistry {
    function registry() external view returns (address);
}
