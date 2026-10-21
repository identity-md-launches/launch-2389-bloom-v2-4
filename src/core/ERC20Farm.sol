// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Farm} from "./Farm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Reusable implementation for owner-whitelisted future, nonrebasing ERC20 farms.
contract ERC20Farm is Farm {
    using SafeERC20 for IERC20;

    constructor(
        address owner_,
        address registry_,
        address treasury_,
        address rewardToken_,
        address asset_,
        uint8 assetDecimals_
    ) Farm(owner_, registry_, treasury_, rewardToken_, asset_, assetDecimals_) {
        if (asset_ == address(0)) revert InvalidAddress();
    }

    function deposit(uint256 assets, address beneficiary, uint256 minSharesOut)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireDepositAllowed();
        _validRecipient(beneficiary);
        if (assets == 0) revert InvalidAmount();
        _settle(beneficiary);
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = IERC20(asset).balanceOf(address(this)) - beforeBalance;
        // Exits require exact transfers, so a taxed receipt is refused before it can take principal.
        if (received != assets) revert InexactTransfer();
        return _mintShares(beneficiary, received, minSharesOut);
    }

    function _verifyAsset() internal view virtual override {
        if (asset.code.length == 0) revert InvalidDependency();
    }

    function _payUnderlying(address payable beneficiary, uint256 amount) internal override {
        _sendExact(asset, beneficiary, amount);
    }
}
