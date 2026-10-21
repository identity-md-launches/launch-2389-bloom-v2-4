// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Verified Ethereum chain-1 dependencies. Evidence and block are in docs/evidence/.
library MainnetAssets {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes32 internal constant IMD_CODE_HASH =
        0x79a1ae149d27d4aae006d4dd75cb834222c9623799bbf34359428aaf66fec3bf;
    bytes32 internal constant SIMD_CODE_HASH =
        0xe8333ecf3ae9263b14d6a1ab59d6f384c16d8609c1725edf31b0dcd1780280e5;
    bytes32 internal constant WETH_CODE_HASH =
        0xd0a06b12ac47863b5c7be4185c2deaad1c61557033f56c7d4ea74429cbb25e23;
}
