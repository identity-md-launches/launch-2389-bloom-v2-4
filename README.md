# BLOOM V2.4 — Job 1

Independent, non-upgradeable Ethereum farming infrastructure. No BLOOM token, liquidity pool or website is created. All dependencies needed to compile and test are ordinary files in `lib/`. Tests run offline with synthetic balances and the recorded mainnet IMD, sIMD and WETH runtimes.

**Deployment status: no mainnet transactions were sent.** Factory and Treasury are ready for the launch service; all three farms are pending the real Job 2 BLOOM token. There are no deployed BLOOM infrastructure addresses, transaction receipts or mainnet gas charges to report. [Deployment handoff](docs/DEPLOYMENT.md), [machine-readable status](docs/deployment-status.json).

The requester supplied by the assignment is **`0xDEA11b3A70b77134424d436f6eb455f1Abbd4449`**. Every application constructor accepts an explicit owner; the deployment helpers enforce that requester. No caller, worker, launch service or factory automatically receives a role. Confirm this address and obtain explicit approval of **each** transaction before submission. This repository contains no signer, key handling or broadcasting code.

## Build and check

```sh
forge build
FOUNDRY_FUZZ_SEED=0xa2dd4bc91022fec0027b6a9355476a6e97def148369ce70d30c412c8b4c5dfc7 forge test
forge fmt --check
python3 scripts/export_artifacts.py --check
```

Compiler: Solidity **0.8.26**, Cancun, optimizer 200 runs, `bytecode_hash = "none"`, no FFI or filesystem permissions. No RPC or environment variables are read by tests. `test/scratch/` is expendable; nothing required to build or run the delivered tests is stored there.

## Components

| Contract | Responsibility |
|---|---|
| `BloomFactory` | Owner-only whitelist, duplicate-free registry, optional CREATE2 farm creation; holds no farming funds |
| `BloomTreasury` | Records fees actually received from registered farms and limits spending to that ledger |
| `StakedBLOOM` | BLOOM principal, with an entirely separate BLOOM reward reserve |
| `StakedSIMD` | Official 24-decimal sIMD principal; direct sIMD deposits or atomic official IMD staking |
| `StakedETH` | Native ETH principal; native withdrawal with canonical WETH fallback to the same beneficiary |
| `ERC20Farm` | Reusable implementation for future reviewed, whitelisted, nonrebasing assets |

Each farm has isolated **internal, nontransferable 18-decimal shares**. They have no ERC20 transfer or approval interface and are not the sIMD protocol's own shares. `sharesOf`, `totalShares`, `previewDeposit`, `previewRedeem`, `accountedAssets`, and `pendingRewards` expose the accounting.

## Assets and official integration

| Asset | Chain-1 address | Decimals |
|---|---|---:|
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | 18 |
| sIMD | `0x9Efa934D9fAd4AE28c998a40195646b965a97247` | **24** |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 18 |
| BLOOM | **Not created; Job 2 dependency** | Verify Job 2 metadata; no assumed value |

At Ethereum block **26,241,636**, `convertToAssets(10^24)` returned **7,976,548,051,082,172,930 IMD base units**. sIMD is a nonrebasing ERC4626 share: yield changes its IMD value, not its token quantity. The farm accounts actual received sIMD units; it never assumes 1:1 conversion and never invokes a DEX. Approval to the official vault is limited to the current deposit and cleared afterward.

The official vault enforces a **one-block redemption hold** that follows transferred shares. A third party can mint positive sIMD to the farm and renew that hold. Accordingly, **farm-mediated IMD redemption is permanently disabled**; `withdrawIMD` explicitly reverts. Immediate sIMD withdrawal remains available, including in the deposit block. The beneficiary can redeem at the official vault later when `maxRedeem` allows it. See [verified addresses, ABI, code and restrictions](docs/INTEGRATION.md).

## Share and fee rules

- Deposit fee: **0%**. Shares are minted from the actual net underlying received, rounded down, with `minSharesOut` and zero-share rejection.
- Each redemption burns the requested shares and computes gross share-backed assets. The user receives `floor(gross × 85 / 100)`, Treasury receives `floor(gross / 100)`, and the remainder stays in the **same** farm. If no shares remain, Treasury receives **all** gross minus the user payout.
- Integer rounding belongs to retained backing while any shares remain, or Treasury at final exit. Small dust burns may pay zero when the caller permits this with `minAssetsOut = 0`. Setting a positive minimum prevents that outcome.
- Retained fees increase the pool-wide share price, including the withdrawing user's remaining shares. Same-block fee sniping and partial-withdrawal self-benefit are allowed. There is no exclusion, lock, cooldown or daily boundary.
- Each redemption applies its fee split once to its gross assets. Claims have **no withdrawal fee**. There is no second fee deduction from the calculated payout.
- Virtual assets/shares normalize underlying decimals to 18-decimal shares. Donations never enter the conversion rate. A final redemption includes all residual backing before its fee split, leaving zero backing and a fresh initial rate for the next depositor.
- Admins cannot recover share backing or reward reserves. `recoverExcess` is limited to measured surplus, including donations/forced ETH; `recoverUnallocatedRewards` is limited to free funding.

The formulas, rounding directions, arithmetic representability limits, liability conservation and reset behavior are specified in [ACCOUNTING.md](docs/ACCOUNTING.md).

## Rewards

Each farm has its own BLOOM reserve and epoch. Funding **never** starts emission. No amount, duration or start date is chosen by this delivery.

`unallocatedRewards`, `scheduledRewards`, `earnedUnpaidRewards`, and `paidRewards` are distinct accounting categories. `earnedUnpaidRewards` conservatively includes unresolved rounding dust; `totalCredits` is its settled subset, not additional backing. Full exits keep integer credits. Sub-token fractions survive partial share changes and claims; a full exit discards a fraction smaller than one BLOOM base unit. When the whole farm empties, only the provably unclaimable remainder returns to free reserve.

Owner operations:

| Operation | Meaning |
|---|---|
| `fundRewards(amount)` | Transfer funding into free reserve, measuring net receipts |
| `configureEpoch(amount, durationDays)` | Reserve budget while stopped; start no clock |
| `startEpoch()` | Explicitly start a configured epoch now |
| `continueEpoch(amount, remainingDays)` | Preserve epoch identity and accrued history; replace remaining budget/duration; this also implements a rate boost |
| `restartEpoch(amount, durationDays)` | Settle elapsed rewards and explicitly start a new epoch |
| `cancelFutureRewards()` | Settle elapsed rewards and return future budget to free reserve |
| `recoverUnallocatedRewards(to, amount)` | Recover only free funds |

Reward-per-share index checkpoints occur before deposits, burns, claims and allocation/epoch changes. Users settle lazily against their saved index without an unbounded loop. Zero-staker emission goes to free reserve and is never distributed retrospectively. The full integer epoch budget vests through cumulative `mulDiv`, so there is no `rate × duration` truncation shortfall. Top-ups remain free until explicitly allocated.

## After launch

1. Verify owner, source, runtime and receipt for Factory and Treasury. The owner calls `Treasury.bindRegistry(factory)` once. No worker can front-run it.
2. **Job 2:** create and verify the real BLOOM contract. Confirm decimals and ordinary exact-transfer, nonrebasing ERC20 behavior. The owner calls `Factory.bindBloom(realBloom)` once. There is no dummy token or public initializer.
3. Owner whitelists BLOOM, official sIMD and native ETH (`address(0)` denotes ETH currency only). Deploy each farm with the exact constructor inputs in the deployment handoff, then register it, or use owner-only `Factory.deployFarm` for atomic creation and registration. One farm per asset; no duplicates or unregister function.
4. Owner calls each farm's `activate()`. This verifies the registry, bound Treasury, metadata, chain 1 and the pinned external runtime hashes. Activation leaves deposits paused and emissions stopped.
5. Owner approves and funds **each** farm separately, then chooses its amount and duration with `configureEpoch`.
6. Owner enables deposits with `setDepositsPaused(false)` and **explicitly** calls `startEpoch()` when intended. Funding/configuration time does not accrue rewards.
7. Record every approved transaction's hash, receipt, block, gas used, effective gas price, contract address, constructor arguments and final roles. Verify that no worker or temporary deployer holds privileges. Explorer publication is a launch-service responsibility.

Every approval, binding, registration, funding, epoch or pause action is a separate transaction unless deliberately batched in a reviewed requester transaction. The brief requires explicit approval before **each** submission. Do not infer approval of a batch from approval of one step.

## Administrative trust and operational responsibilities

Ownership uses a two-step handover. The current owner can permanently renounce selected powers with `renouncePowers(mask)` or explicitly renounce ownership. Nothing auto-renounces. Bits: configuration `1`, rewards `2`, deposit pause `4`, excess/free-funding recovery `8`, Treasury spending `16`. Renunciations persist across ownership transfers. Treasury and Factory hold no user share ledger. Their owners cannot alter an existing farm's immutable token, Treasury or registry address.

Pausing or removing a whitelist entry blocks new deposits, not withdrawals or earned claims. Initial epoch starts/restarts require enabled deposits; continuing an already-running epoch can occur while deposits are paused. Renouncing pause control while paused leaves new deposits disabled; exits and claims remain available. Cancel pending schedules and recover genuinely free funds before renouncing powers if that is the desired disposition. Keep ownership across components coordinated before registering new farms.

Future asset admission is a trusted owner decision: review its transfers, decimals, code and economic behavior first. Outbound tax/rebase/confiscation behavior is unsupported; exact payout checks revert rather than silently underpaying. Negative token balance changes can make an affected farm insolvent; there is no admin loss-socialization or principal-rescue mechanism. sIMD's underlying IMD value can change without changing farm principal quantity. No yield or BLOOM reward rate is guaranteed.

Production use still requires the network's independent adversarial review. The delivered deterministic tests and invariant checks are not a security audit. [Validation record](docs/VALIDATION.md), [dependency provenance](docs/DEPENDENCIES.md), [ABIs](abi/), [source and bytecode-template hashes](docs/artifact-hashes.json).
