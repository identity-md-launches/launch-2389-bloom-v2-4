// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Farm} from "./core/ERC20Farm.sol";
import {MainnetAssets} from "./MainnetAssets.sol";
import {IStakedIMD} from "./interfaces/IBloom.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakedSIMD is ERC20Farm {
    using SafeERC20 for IERC20;

    string public constant name = "stakedSIMD";
    address public constant IMD = MainnetAssets.IMD;
    /// @notice The official vault has a one-block redemption hold, transferable with sIMD.
    bool public constant imdRedemptionEnabled = false;
    error IMDRedemptionDisabled();
    event IMDStaked(address indexed caller, address indexed beneficiary, uint256 imdIn, uint256 simdReceived);

    constructor(address owner_, address registry_, address treasury_, address bloom_)
        ERC20Farm(owner_, registry_, treasury_, bloom_, MainnetAssets.SIMD, 24)
    {}

    function depositIMD(uint256 imdAssets, address beneficiary, uint256 minSIMDOut, uint256 minSharesOut)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireDepositAllowed();
        _validRecipient(beneficiary);
        if (imdAssets == 0) revert InvalidAmount();
        _settle(beneficiary);
        uint256 beforeIMD = IERC20(IMD).balanceOf(address(this));
        uint256 beforeSIMD = IERC20(asset).balanceOf(address(this));
        IERC20(IMD).safeTransferFrom(msg.sender, address(this), imdAssets);
        uint256 receivedIMD = IERC20(IMD).balanceOf(address(this)) - beforeIMD;
        if (receivedIMD != imdAssets) revert InexactTransfer();
        IERC20(IMD).forceApprove(asset, receivedIMD);
        // Official ERC-4626 deposit only. Ignore its return value and account the actual balance change.
        IStakedIMD(asset).deposit(receivedIMD, address(this));
        IERC20(IMD).forceApprove(asset, 0);
        if (IERC20(IMD).balanceOf(address(this)) != beforeIMD) revert InexactTransfer();
        uint256 receivedSIMD = IERC20(asset).balanceOf(address(this)) - beforeSIMD;
        if (receivedSIMD < minSIMDOut) revert Slippage();
        shares = _mintShares(beneficiary, receivedSIMD, minSharesOut);
        emit IMDStaked(msg.sender, beneficiary, receivedIMD, receivedSIMD);
    }

    /// @notice Explicitly unavailable: the external hold cannot satisfy unconditional immediate IMD exits.
    /// @dev Withdraw sIMD, then redeem directly at the official vault when its maxRedeem permits it.
    function withdrawIMD(uint256, address, uint256) external pure {
        revert IMDRedemptionDisabled();
    }

    function _validRecipient(address recipient) internal view override {
        super._validRecipient(recipient);
        if (recipient == IMD) revert InvalidAddress();
    }

    function _verifyAsset() internal view override {
        super._verifyAsset();
        if (
            IERC20Metadata(IMD).decimals() != 18 || IStakedIMD(asset).asset() != IMD || rewardToken == IMD
                || rewardToken == asset || IMD.codehash != MainnetAssets.IMD_CODE_HASH
                || asset.codehash != MainnetAssets.SIMD_CODE_HASH
        ) revert InvalidDependency();
    }
}
