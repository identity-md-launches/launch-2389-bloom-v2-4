// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IBloomRegistry {
    function owner() external view returns (address);
    function treasury() external view returns (address);
    function bloom() external view returns (address);
    function farmForAsset(address asset) external view returns (address);
    function isAssetWhitelisted(address asset) external view returns (bool);
    function isFarm(address farm) external view returns (bool);
}

interface IBloomFarm {
    function owner() external view returns (address);
    function registry() external view returns (address);
    function treasury() external view returns (address);
    function asset() external view returns (address);
    function rewardToken() external view returns (address);
    function active() external view returns (bool);
    function depositsPaused() external view returns (bool);
}

interface IFeeTreasury {
    function receiveTokenFee(address token, uint256 amount) external returns (uint256 received);
    function receiveNativeFee() external payable;
}

interface IStakedIMD {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function maxDeposit(address receiver) external view returns (uint256 assets);
    function maxRedeem(address owner) external view returns (uint256 shares);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
