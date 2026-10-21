// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Farm} from "./core/Farm.sol";
import {MainnetAssets} from "./MainnetAssets.sol";
import {IWETH} from "./interfaces/IBloom.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract StakedETH is Farm {
    string public constant name = "stakedETH";
    address public constant WETH = MainnetAssets.WETH;
    uint256 public constant NATIVE_SEND_GAS = 50_000;
    event NativePaid(address indexed beneficiary, uint256 amount);
    event WETHFallback(address indexed beneficiary, uint256 amount);

    constructor(address owner_, address registry_, address treasury_, address bloom_)
        Farm(owner_, registry_, treasury_, bloom_, address(0), 18)
    {}

    function deposit(address beneficiary, uint256 minSharesOut)
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        _requireDepositAllowed();
        _validRecipient(beneficiary);
        _settle(beneficiary);
        return _mintShares(beneficiary, msg.value, minSharesOut);
    }

    function _verifyAsset() internal view override {
        if (
            WETH.codehash != MainnetAssets.WETH_CODE_HASH || IERC20Metadata(WETH).decimals() != 18
                || rewardToken == WETH
        ) {
            revert InvalidDependency();
        }
    }

    function _payUnderlying(address payable beneficiary, uint256 amount) internal override {
        if (amount == 0) return;
        bool ok;
        // Bound execution and copy no return data, including a beneficiary's oversized revert data.
        assembly ("memory-safe") {
            ok := call(NATIVE_SEND_GAS, beneficiary, amount, 0, 0, 0, 0)
        }
        if (ok) {
            emit NativePaid(beneficiary, amount);
            return;
        }
        uint256 beforeWETH = IERC20(WETH).balanceOf(address(this));
        IWETH(WETH).deposit{value: amount}();
        if (IERC20(WETH).balanceOf(address(this)) - beforeWETH != amount) revert InexactTransfer();
        _sendExact(WETH, beneficiary, amount);
        emit WETHFallback(beneficiary, amount);
    }
}
