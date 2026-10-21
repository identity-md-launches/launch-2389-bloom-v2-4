// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Managed} from "./core/Managed.sol";
import {IBloomFarm} from "./interfaces/IBloom.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Registry and permissioned CREATE2 factory. It holds no principal or reward funds.
/// @dev Generic initcode keeps farm creation code out of the factory's EIP-170 runtime budget.
contract BloomFactory is Managed {
    address public immutable treasury;
    address public bloom;
    mapping(address => bool) public isAssetWhitelisted;
    mapping(address => address) public farmForAsset;
    mapping(address => bool) public isFarm;
    address[] public farms;

    error InvalidAddress();
    error AlreadyBound();
    error InvalidToken();
    error NotWhitelisted();
    error DuplicateFarm();
    error InvalidFarm();
    error DeploymentFailed();
    event BloomBound(address indexed bloom, uint8 decimals);
    event AssetWhitelisted(address indexed asset, bool allowed);
    event FarmRegistered(address indexed asset, address indexed farm);
    event FarmDeployed(address indexed farm, bytes32 indexed salt, bytes32 initCodeHash);

    constructor(address owner_, address treasury_) Managed(owner_) {
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
    }

    /// @notice BLOOM does not exist in Job 1. Only the requester can permanently bind Job 2's real token.
    function bindBloom(address token) external withPower(CONFIG) {
        if (bloom != address(0)) revert AlreadyBound();
        if (token.code.length == 0) revert InvalidToken();
        uint8 d = IERC20Metadata(token).decimals();
        if (d > 36) revert InvalidToken();
        bloom = token;
        emit BloomBound(token, d);
    }

    /// @param asset address(0) is the native ETH currency, never an unconfigured ERC20 placeholder.
    function whitelistAsset(address asset, bool allowed) external withPower(CONFIG) {
        if (allowed && asset != address(0) && asset.code.length == 0) revert InvalidToken();
        isAssetWhitelisted[asset] = allowed;
        emit AssetWhitelisted(asset, allowed);
    }

    function registerFarm(address farm) external withPower(CONFIG) {
        _register(farm);
    }

    function deployFarm(bytes calldata initCode, bytes32 salt)
        external
        withPower(CONFIG)
        returns (address farm)
    {
        bytes memory code = initCode;
        if (code.length == 0 || code.length > 49_152) revert DeploymentFailed();
        if (predictFarmAddress(keccak256(code), salt).code.length != 0) revert DeploymentFailed();
        assembly ("memory-safe") {
            farm := create2(0, add(code, 32), mload(code), salt)
        }
        if (farm == address(0)) revert DeploymentFailed();
        _register(farm);
        emit FarmDeployed(farm, salt, keccak256(code));
    }

    function predictFarmAddress(bytes32 initCodeHash, bytes32 salt) public view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
        );
    }

    function _register(address farm) internal {
        if (farm.code.length == 0 || bloom == address(0)) revert InvalidFarm();
        IBloomFarm f = IBloomFarm(farm);
        address underlying = f.asset();
        if (!isAssetWhitelisted[underlying]) revert NotWhitelisted();
        if (isFarm[farm] || farmForAsset[underlying] != address(0)) revert DuplicateFarm();
        if (
            f.owner() != owner() || f.registry() != address(this) || f.treasury() != treasury
                || f.rewardToken() != bloom || f.active() || !f.depositsPaused()
        ) revert InvalidFarm();
        // Registration is permanent, so a farm must already satisfy every activation precondition that
        // registration itself does not supply (chain, decimals, pinned dependency runtimes).
        f.verifyDependencies();
        isFarm[farm] = true;
        farmForAsset[underlying] = farm;
        farms.push(farm);
        emit FarmRegistered(underlying, farm);
    }

    function farmCount() external view returns (uint256) {
        return farms.length;
    }
}
