# Local validation record

Solidity 0.8.26 / Foundry 1.8.5; executed 2026-10-21. No mainnet write transaction was executed.

| Check | Result |
|---|---|
| `forge build` | Pass |
| `forge test --gas-report` with the assignment's seed | **62 reported tests passed**, 0 failed, 0 skipped, 7 suites |
| `forge fmt --check` | Pass |
| Two fuzz tests | 256 runs each |
| Stateful invariant campaign | 128 runs × 64 calls = **8,192 operations**, 0 reverts; two conservation/solvency invariants |
| `python3 scripts/export_artifacts.py --check` | ABIs and hashes match |
| `forge script script/DeployCore.s.sol:DeployCore --chain-id 1` | Local simulation passed; no broadcast operations exist |
| Python preparation | Scripts parse; unsigned Treasury plan produced with exact requester and no receipt/signature |
| Read-only dependency verifier | Pass at block 26,241,812; exact runtime hashes/decimals unchanged |

Seed: `0xa2dd4bc91022fec0027b6a9355476a6e97def148369ce70d30c412c8b4c5dfc7`, pinned in `foundry.toml` and explicitly supplied to the final test command. Tests use no RPC, fork, local files, clock waits, environment lookups or shared external state.

[Full test/gas output](validation/forge-test.txt). [Core local simulation](validation/core-simulation.txt). Addresses printed by that simulation are **local ephemeral addresses, not Ethereum deployments**. Its reported **2,154,742 gas** describes that local rehearsal, not a mainnet transaction or fee quote. The test gas report's zero deployment-cost entries are a harness measurement artifact, not free deployments. Actual receipts/gas remain pending. A launch service's outer transaction, cold/warm access patterns, calldata and approval actions change costs.

## Exercised behavior

- Partial/full/same-block withdrawals, pool-wide retained-fee appreciation, self-benefit, exact rounding conservation, final 15% Treasury split and zero-supply reset.
- Donation isolation, 6/18/24-decimal normalization, virtual assets/shares, zero-share rejection, min-share/min-net-asset slippage and atomic rollback. Uint256 boundary tests cover virtual-offset headroom and oversized reward schedules leaving only one share quantum.
- Separate same-token BLOOM reward funding, full-exit credits, claims without fees, no accrual from funding/configuration alone, late deposits and zero-staker intervals.
- Continue/boost/Restart, unchanged past credits, unavailable earned budget, top-ups, cancellation, free-only recovery, segment completion, per-user fractional credits and dust release.
- Mainnet IMD/sIMD runtimes: direct sIMD, atomic IMD conversion at a changed rate, actual net receipt, cleared approval, nonrebasing yield semantics, official hold propagation and dust-mint interference, explicit IMD redemption disablement, slippage/protocol failure rollback, independent BLOOM rewards.
- Mainnet WETH runtime: native success, rejecting beneficiary, gas exhaustion, oversized revert data, WETH delivery to the same beneficiary, wrap/transfer failure rollback, reentrancy prevention and forced ETH isolation.
- Owner-only binding/administration, two-step ownership, selective irreversible power renunciation, no worker privileges, whitelist/registry constraints, duplicate rejection and CREATE2 creation/registration.
- Treasury spending bounded by received fees, unsolicited funds excluded, failed transfer rollback, and disallowing fake fee recording by unregistered callers.
- All application constructors succeed with dependencies absent; script helpers fail on missing/wrong inputs. Application runtime sizes and the protected test's reachable-opcode rule are checked directly. No reachable DELEGATECALL, CALLCODE or SELFDESTRUCT is present.

## Application size limits

| Contract | Runtime bytes |
|---|---:|
| BloomFactory | 4,051 |
| BloomTreasury | 4,623 |
| StakedBLOOM | 14,526 |
| StakedSIMD | 16,584 |
| StakedETH | 15,858 |
| ERC20Farm | 14,407 |

All are below 24,576 bytes; creation bytecode is below 49,152 bytes. Exact hashes and immutable slot references are in [artifact-hashes.json](artifact-hashes.json). Those runtime hashes are compiler templates; receipt-based deployed hashes are pending.

## Review scope and limits

This was implementation testing and a focused local review, **not an independent security audit**. No Slither, Mythril, formal proof or mainnet write test was run. The independent network review remains a release dependency. The protected manifest-driven harness needs the later launch service's manifest/environment and was not represented as executed; equivalent constructor/owner/runtime checks were run locally against all application types.

Forge's heuristic lint output includes calls/events under the shared reentrancy guard, owner modifiers preceding that guard, timestamp-driven emission, strict balance-delta comparisons, native-asset zero sentinels, and an ignored ERC4626 return value. These are deliberate code paths: exact deltas are independently measured, native ETH is an explicit currency, epochs are timestamp based, all custody-changing entry points use the common guard, and sIMD's return value cannot inflate recorded receipts. The native recipient call also uses bounded gas and copies no return data. Compiler/lint output is not claimed to be a security proof.

The official-runtime tests run synthetic storage/balances rather than a complete fork snapshot. They establish relevant executable interface/transfer/hold behavior, not economic safety of all possible protocol states. Token-side confiscation, rebases or transfer-tax changes are unsupported and can make the affected asset unusable; owner admission and Job 2 token review are explicit trust responsibilities. No worker-owned recovery or replacement route was added to evade those constraints.
