# Deployment handoff and Job 2 dependencies

## Current state

**No BLOOM infrastructure has been deployed by this job. No transactions were broadcast.** Source, ABI, deployment rehearsals and unsigned-transaction preparation are delivered. Factory/Treasury are ready for the launch service; all farms await the actual Job 2 BLOOM address. Existing official IMD/sIMD/WETH addresses are external dependencies, not deployments by this job.

| Component | Status | Address / receipt / gas used |
|---|---|---|
| BloomTreasury | Ready for approved launch | Pending / none / not incurred |
| BloomFactory | Ready for approved launch, after Treasury address is known | Pending / none / not incurred |
| StakedBLOOM | Source complete; defer until real BLOOM exists | Pending / none / not incurred |
| StakedSIMD | Source complete; defer until real BLOOM exists | Pending / none / not incurred |
| StakedETH | Source complete; defer until real BLOOM exists | Pending / none / not incurred |
| ERC20Farm | Optional future whitelisted farm implementation | Not part of the initial launch |

Only Treasury and Factory belong in the immediate application launch. Do not insert a zero, dead, test or guessed BLOOM into any constructor. The manifest is a later launch-service deliverable; this repository deliberately has **no `launch.json`**.

## Reproducible inputs

- Chain: **Ethereum 1**.
- Owner for every component: **`0xDEA11b3A70b77134424d436f6eb455f1Abbd4449`**, supplied by the assignment. In the service's manifest this is `$owner`, never the factory/caller or `tx.origin`.
- No constructor takes ETH. All owner arguments are explicit; no constructor invokes or checks code on another contract.
- Compiler/settings are pinned in `foundry.toml`. Production libraries are internal and inlined; no link placeholders or upgradeable proxy is used.
- Constructors take static fields only and fewer than 16 arguments.

| Contract | Constructor types | Ordered inputs |
|---|---|---|
| BloomTreasury | `(address owner_)` | requester |
| BloomFactory | `(address owner_, address treasury_)` | requester, actual Treasury deployment |
| StakedBLOOM | `(address owner_, address registry_, address treasury_, address bloom_, uint8 bloomDecimals_)` | requester, actual Factory, actual Treasury, verified Job 2 BLOOM, its verified decimals |
| StakedSIMD | `(address owner_, address registry_, address treasury_, address bloom_)` | requester, actual Factory, actual Treasury, verified Job 2 BLOOM |
| StakedETH | `(address owner_, address registry_, address treasury_, address bloom_)` | requester, actual Factory, actual Treasury, verified Job 2 BLOOM |
| ERC20Farm | `(address owner_, address registry_, address treasury_, address rewardToken_, address asset_, uint8 assetDecimals_)` | requester, existing Factory, existing Treasury, bound BLOOM, reviewed future token, its verified decimals |

Token addresses in farms, the Factory's Treasury address, and each farm's registry/Treasury addresses are immutable. Factory's BLOOM can be bound **once** by its current owner after verifying Job 2. Treasury's registry can be bound **once** by its current owner, with reciprocal ownership/Treasury checks. These are restricted setters; no worker-held initializer exists. Constructors assign no temporary roles.

## Rehearsals and unsigned plans

`script/DeployCore.s.sol` deploys Treasury/Factory in a **local simulation**, with the supplied requester as owner. The three `Deploy*Farm.s.sol` helpers accept actual dependency arguments and check their code/owner/binding before simulating creation. They do not initialize or enable anything. **None contains a broadcast cheatcode**, even if a caller passes a broadcast CLI flag. Tests call the helper methods directly, independent of caller and environment.

Example core rehearsal:

```sh
forge script script/DeployCore.s.sol:DeployCore --chain-id 1
```

Prepare one reviewable unsigned Treasury creation payload:

```sh
python3 scripts/prepare_deployment.py BloomTreasury \
  --confirm-owner 0xDEA11b3A70b77134424d436f6eb455f1Abbd4449
```

For Factory, additionally supply `--treasury ACTUAL_DEPLOYED_TREASURY --rpc PUBLIC_ETHEREUM_RPC`. For each farm supply `--registry ACTUAL_FACTORY --treasury ACTUAL_TREASURY --bloom VERIFIED_JOB2_BLOOM --rpc PUBLIC_ETHEREUM_RPC`; StakedBLOOM also requires `--bloom-decimals VERIFIED_DECIMALS`. These uppercase names describe required inputs, not executable defaults or deployment values. Missing/zero dependencies are refused, and the preparation script checks on-chain ownership/binding. Do not infer token legitimacy from symbol alone.

The output contains constructor inputs, ABI encoding, exact initcode and keccak hash, but **no signature, nonce, fee quote, receipt or invented gas cost**. The concrete [unsigned Treasury payload](../deployment/BloomTreasury.unsigned.json) is included for review and has not been submitted. The launch service uses its own reviewed factory transaction and these exact application inputs; direct creation transaction data is not a substitute for the service's transaction envelope. Factory/Treasury addresses must come from actual receipts or a reviewed service prediction. No wallet is requested or read.

`python3 scripts/export_artifacts.py` regenerates the six application ABIs and `docs/artifact-hashes.json`. `--check` fails on drift. Runtime hashes there are **templates with zeroed immutable slots**, not deployed runtime hashes. After deployment, compare the runtime while substituting the constructor's actual immutable values, and record the real `eth_getCode` hash. Do not compare a template hash directly with an instantiated immutable-bearing contract.

## Activation transactions, all explicitly approved

The requester must approve **each** transaction immediately before it is submitted. A script invocation, test success, or approval of one step is not authority for other transactions.

1. Deploy Treasury, then Factory, with the requester owner and exact Treasury reference. Verify successful receipts, addresses, bytecode and `owner`/`pendingOwner`. Keep the receipt ledger; do not claim completion based on a simulated address.
2. Requester calls `Treasury.bindRegistry(factory)` once. This does not bind BLOOM or create farms.
3. **Wait for Job 2's real token.** Verify chain, verified source, deployment receipt, token address, decimals, transfer mechanics, owner powers and absence of unexpected rebase/tax. No BLOOM amount or supply is fabricated here.
4. Requester calls `Factory.bindBloom(bloom)`. Whitelist BLOOM and official sIMD; whitelist `address(0)` as the native ETH currency. Every token/asset decision remains visible in events.
5. Deploy the three farms with their exact constructor inputs. Requester registers each, or instead calls `Factory.deployFarm(initCode, salt)` for atomic creation/registration. The factory rejects duplicate farm or underlying asset registrations and wrong owner/registry/Treasury/reward bindings, and runs the farm's `verifyDependencies()` (chain 1, token decimals, pinned IMD/sIMD/WETH runtimes) so that a misconfigured farm, for example a StakedBLOOM built with the wrong `bloomDecimals_`, is refused rather than occupying the asset slot permanently; `deployFarm` rolls the creation back in that case and the salt stays reusable. A future farm is a trusted reviewed implementation admitted by the owner, not arbitrary public plugin code.
6. Requester calls `activate()` on each farm. It verifies chain 1, registration, Treasury binding, decimals and known IMD/sIMD/WETH bytecode hashes. Deposits remain paused; emissions remain stopped. Farm token addresses cannot be rebound.
7. Requester approves each farm to pull the intended BLOOM funding, calls `fundRewards`, and confirms `fundedRewards`, `unallocatedRewards` and custody. Funding one farm does not fund another.
8. Requester chooses each farm's amount/duration in whole days and calls `configureEpoch`. No budget or days value is predetermined. Scheduled budget is reserved but accrues nothing yet.
9. Requester calls `setDepositsPaused(false)`, then explicitly `startEpoch()` at the desired time. If there are no shares yet, elapsed emission returns to free reserve; first depositors cannot claim it retrospectively.
10. Record and verify final roles and state across all contracts. Optional future handovers use `transferOwnership` followed by acceptance by the new owner. Renouncing selected powers or ownership is never automatic and needs its own explicit decision/approval.

## Exact outstanding dependencies and responsibilities

**Job 2 supplies:** real BLOOM deployment and receipt, verified source/ABI/code identity, token decimals and transfer behavior, plus actual funding transferred to each farm. It does not need to change this farm source. The StakedBLOOM constructor's decimals are a read from that actual token, not an assumption of 18.

**Requester supplies during activation:** chosen amounts, durations and start time; approval of every mainnet transaction. These are owner-configurable and do not block source delivery. There are deliberately no default allocations, reward rates, boosts, launch dates or signatures.

**Launch service supplies:** accepted manifest, deployment envelope/predictions, transaction execution after approval, explorer source verification, receipts, actual gas, final address/role ledger and independent review. This job cannot invent receipts or service-specific factory parameters. Source-level runtime bounds and constructor rehearsals pass locally.

**External protocol dependency:** immediate redemption to IMD is unavailable because of the official hold. Default sIMD exits remain immediate. Supporting a future protocol with unconditional atomic redemption would require separately reviewed new source; there is no mutable arbitrary adapter target in the deployed farm.

For each actual submitted transaction record: approved intent, chain, from, to/creation target, value, input hash, exact constructor arguments if applicable, transaction hash, receipt status, block number/hash, gas used, effective gas price, contract address, runtime code hash, verified-source URL, final owner/pending owner, renounced powers, deposit pause, activation and epoch status. Until then those receipt fields remain explicitly pending.
