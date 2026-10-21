# Verified Ethereum dependencies

Verification date: **2026-10-21 UTC**. RPC snapshot: **Ethereum chain 1, block 26,241,636**. The evidence is a snapshot, not a promise about future balances or exchange rates. No account was impersonated and no transaction was sent to mainnet.

## Provenance and recorded evidence

- Official IMD token page: <https://imd.fun/token/>. It identifies Ethereum IMD and describes increasing IMD value per sIMD.
- Official POOL4 documentation: <https://pool4.imd.fun/docs>. Its staking-vault and IMD links identify the addresses below; its parameter table discloses the one-block unstake hold.
- Canonical WETH address: [Uniswap's Ethereum deployment reference](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-ethereum-deployments#wrapped-native-token-addresses).
- Public RPC `https://ethereum-rpc.publicnode.com`: `eth_chainId`, code and metadata/conversion reads pinned to the recorded block.
- Sourcify verified compilation/source/ABI: `https://sourcify.dev/server/v2/contract/1/ADDRESS?fields=all` for each listed address. The downloaded runtime bytes matched the independent RPC bytes. IMD and sIMD have `exact_match` runtime verification; WETH has `match` (historical compiler/metadata matching). Each is reported as non-proxy by Sourcify.
- Etherscan and Blockscout requests returned HTTP 403 during the verification. Their links are provided for the operator; no successful source retrieval from those endpoints is claimed.

The full ABI and original corresponding source/notices for each dependency are recorded as evidence, not compiled production code:

| File | Contents |
|---|---|
| [mainnet-reads.json](evidence/mainnet-reads.json) | Addresses, pinned on-chain code, code hashes, metadata, conversions and read outcomes |
| [simd-verification.json](evidence/simd-verification.json) | Exact verified `StakedIMD` source, Solady bases, full ABI, deployment and compiler provenance |
| [imd-verification.json](evidence/imd-verification.json) | Exact verified `BridgedFP`/OFT source and ABI; metadata was subsequently renamed to Identity.md / IMD |
| [weth-verification.json](evidence/weth-verification.json) | Verified canonical WETH9 source, original license, ABI and deployment metadata |

## Addresses and code identity

| Contract | Address | Runtime keccak256 |
|---|---|---|
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | `0x79a1ae149d27d4aae006d4dd75cb834222c9623799bbf34359428aaf66fec3bf` |
| sIMD | `0x9Efa934D9fAd4AE28c998a40195646b965a97247` | `0xe8333ecf3ae9263b14d6a1ab59d6f384c16d8609c1725edf31b0dcd1780280e5` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | `0xd0a06b12ac47863b5c7be4185c2deaad1c61557033f56c7d4ea74429cbb25e23` |

[IMD explorer](https://etherscan.io/address/0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7#code), [sIMD explorer](https://etherscan.io/address/0x9Efa934D9fAd4AE28c998a40195646b965a97247#code), [WETH explorer](https://etherscan.io/address/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2#code).

Farm activation checks the exact recorded runtime hashes, chain 1 and relevant metadata/underlying relationships. No owner setter can replace these dependencies. If verification fails, activation reverts and the source/dependency must be reviewed; there is no bypass setter.

## IMD and sIMD semantics

Recorded reads:

| Read | Result |
|---|---|
| IMD `symbol()`, `name()`, `decimals()` | `IMD`, `Identity.md`, `18` |
| sIMD `symbol()`, `name()`, `decimals()` | `sIMD`, `Staked IMD`, **`24`** |
| sIMD `asset()` | Official IMD above |
| sIMD `totalSupply()` | `237433265352441504991101829951` raw sIMD |
| sIMD `totalAssets()` | `1893897850009093701906658` raw IMD |
| sIMD `convertToAssets(10^24)` | `7976548051082172930` raw IMD |
| sIMD `convertToShares(10^18)` | `125367514066981727757597` raw sIMD |
| sIMD `paused()` | `false` |
| sIMD `owner()` | Renounced (zero); this is an observed role state, not a deployment placeholder |

A speculative `minHoldBlocks()` read reverted; it is **not** part of the verified ABI and is not used by the integration. The actual fixed hold is proven by `lastDepositBlock`, the source's `_withdraw`/`maxRedeem` checks, and offline execution of the matching deployed runtime.

The official sIMD is Solady ERC4626 with a decimal offset of 6, virtual assets/shares and a constant asset address. Its balance is an ordinary transferable ERC20 quantity. `convertToAssets` rounds down in underlying IMD base units; `convertToShares` rounds down in sIMD base units. Deposits use `deposit(uint256 assets, address receiver) returns (uint256 shares)`; actual farm receipt is measured independently of the returned number. IMD token allowances are normal ERC20 approvals; the OFT's `approvalRequired()` concerns bridging, not this staking deposit. The farm does not bridge.

The IMD implementation inherits OpenZeppelin ERC20 transfers without an overridden tax/rebase transfer hook. Its owner can change metadata and LayerZero configuration; it is not an immutable economic guarantee of backing. sIMD yield comes from additional IMD in the official vault. That raises the IMD value of existing sIMD while leaving holders' sIMD quantities unchanged. Farm accounting therefore does **not** synchronize donations into principal or invent rebases.

## Redemption restriction and deliberate disabled path

The official source permits atomic ERC4626 redemption only when the holder's last share-increasing block is older than the current block and the vault is unpaused. A positive mint stamps the recipient. A positive transfer carries forward the sender's newer stamp. Zero transfers and burns do not stamp. The official pause checks apply to deposit/mint/withdraw/redeem; ordinary share transfers are not paused by those funnels. At the recorded block, ownership is renounced and pause is false.

A third party can `deposit(1, farm)` and stamp the farm for that block. Thus even long-held farm sIMD cannot promise an unconditional immediate IMD redemption. The task expressly requires disabling a locked path: **`imdRedemptionEnabled` is permanently false, and `withdrawIMD` always reverts before any change.** No asynchronous queue, synthetic IMD, delayed farm liability, DEX swap or guessed redemption method is substituted.

The default path transfers sIMD immediately, with the ordinary BLOOM farm fee split. The official hold may follow the shares to the beneficiary, who can check `maxRedeem` and redeem directly at the official vault later. Anyone can also stamp a beneficiary by depositing to it; that is an external-protocol dependency, not a farm cooldown.

## Offline executable verification

`test/fixtures/OfficialIMD.sol`, `OfficialSIMD.sol` and `OfficialWETH.sol` contain the unmodified recorded runtimes. Integration tests install those bytes with `vm.etch`, initialize **synthetic local** balances (and WETH's documented decimals storage), then execute transfers, exact approvals, non-1:1 staking, yield changes, the hold, its propagation, dust-mint interference and native wrapping. They do not fork or need network access. These are real-runtime interoperability tests in synthetic state, not assertions that the tests reproduced every mainnet state variable.

A second successful script run at **block 26,241,812** confirmed the same three runtime hashes and decimals; see [dependency-revalidation.json](evidence/dependency-revalidation.json). The public RPC refused an older-block replay after its free recent-state window expired, answering `Archive requests require a personal token`. No credentials were requested or used; the original successful snapshot remains recorded.

To repeat the read-only identity checks, pin one current block automatically:

```sh
python3 scripts/verify_mainnet.py --rpc https://ethereum-rpc.publicnode.com
```

This command prints code hashes, decimals, asset identity, pause/owner state and current-at-that-block conversion data. It never signs or submits anything. The optional `--block 26241636` can replay the original height on an archive-capable RPC. Save a fresh snapshot before activation and verify the real Job 2 BLOOM separately.
