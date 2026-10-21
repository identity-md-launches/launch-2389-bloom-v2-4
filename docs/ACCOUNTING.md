# Accounting specification

All token amounts are raw units. A farm's share unit is `10^-18` of an internal share. Shares cannot be transferred or approved. `A = accountedAssets`, `S = totalShares`; these are separate from all BLOOM reward bookkeeping, even when the underlying is BLOOM itself.

## Share conversions and donations

For underlying decimals `d` (supported range 0–36):

```
Va = 10^max(d - 12, 0)
Vs = 10^(18 - min(d, 12))          # never below 10^6 share quanta
sharesOut = floor(netAssets * (S + Vs) / (A + Va))
gross = floor(sharesBurned * (A + Va) / (S + Vs))   # partial supply redemption
```

OpenZeppelin `Math.mulDiv` computes the full 512-bit product before division. Minting rejects totals that would leave insufficient uint256 headroom for either virtual offset, so an extreme deposit cannot make later partial exits overflow. `Va`/`Vs` are the same virtual position expressed in raw underlying units and in share quanta, so initially 1 whole underlying token mints 1 whole farm share for every supported decimal count. For 18-decimal BLOOM and ETH `Va = Vs = 10^6`; for the verified 24-decimal sIMD `Va = 10^12`, `Vs = 10^6`, so at an empty farm less than 1,000,000 raw sIMD units would mint zero farm shares and is rejected; for a 6-decimal future asset `Va = 1`, `Vs = 10^12`.

The retained 14% fee is the sanctioned way to raise `A` without minting, so a holder who exits all but one quantum, or a 1-wei holder who stays in after a large exit, leaves one real share backed by 14% of the exited gross. Because the virtual position is at least `10^6` quanta, the price seen by the next depositor is `(A + Va) / (S + Vs) <= (A + Va) / 10^6` per quantum, and the next deposit's rounding loss is bounded by that single quantum: at most one millionth of the backing, before the ordinary 15% withdrawal fee. Setting up such a state costs the remaining holder 1% of the exited gross immediately and 15% of the retained backing at its own final exit, so it cannot profit from later depositors even though the last redemption pays out the whole residual `A`. The test `testRetainedFeeInflationSetupIsUnprofitableAndLossBoundedByOneQuantum` fixes both bounds.

The farm uses recorded receipt amounts, never its live token balance, to change `A`. Thus unsolicited transfers cannot inflate share price, affect a new depositor's mint, or become reward funding. `excessBalance(token)` computes surplus after reserving **both** underlying and reward obligations for a same-token farm. Excess can be recovered only up to that surplus.

On the **last supply redemption**, gross is exactly `A`, avoiding virtual-offset residue becoming a windfall for the next depositor or stranded assets. The final fee split sends every remaining unit out. `S = 0` therefore implies `A = 0`; unrelated donations and unpaid rewards stay segregated. No reward index reset can erase a former holder's claim.

## Withdrawal conservation

```
user = floor(gross * 8500 / 10000)
if shares remain:
    treasury = floor(gross * 100 / 10000)
    retained = gross - user - treasury
else:
    treasury = gross - user
    retained = 0
A_after = A_before - gross + retained
S_after = S_before - burned
```

Exactly: `gross = user + treasury + retained` and `A_before - A_after = user + treasury`. At most the fee split's integer rounding residue goes to retained backing, or Treasury at final exit. Retention is not a separate asset transfer and is not counted again as newly funded rewards. Subsequent redemptions use the resulting share-backed pool value and perform one fee split on that redemption's gross. Reward claims never invoke this split.

Partial exits leave the user's remaining shares eligible for their fraction of retained fees. Anyone may deposit immediately before an exit and participate; this is the accepted economic behavior. There is no eligibility timestamp or address exemption.

`minSharesOut` bounds the minted amount. `minAssetsOut` bounds the **net user payout**, after the split. An ERC20 deposit must credit the farm with exactly the requested amount, and outbound ERC20 balance changes must match both the farm debit and recipient credit; taxed transfers fail atomically in both directions, so a taxed token can never hold principal it could not pay back. Beneficiaries that would strand a payout (the farm, Treasury, registry, underlying or reward token, WETH for the ETH farm, IMD for the sIMD farm) are rejected before any state change. Very small burns may yield zero raw payout, allowed only when `minAssetsOut` permits it, so dust cannot prevent zero-supply reset.

## Reward conservation

Stored buckets:

- `F = unallocatedRewards`: funded but free, including skipped emission and released dust.
- `U = scheduledRewards`: not yet vested, including a configuration that has not started.
- `L = earnedUnpaidRewards`: conservatively reserved for accrued rewards, including unresolved rounding residue.
- `P = paidRewards`: lifetime actual payouts.
- `C = totalCredits`: **subset of L**, integer credits already settled into user accounts.
- `R = recoveredRewards`, `T = fundedRewards`: lifetime net recovered and funded values.

Invariants:

```
T = F + U + L + P + R
C <= L
sum(user.rewardCredit) = C
rewardReserve = F + U + L
BLOOM balance >= rewardReserve + (A if BLOOM is underlying else 0)
underlying balance >= A + (rewardReserve if underlying is BLOOM else 0)
```

Views do not force a checkpoint, so `U` may include emission that has accrued since the last transaction. `pendingRewards(user)` projects that elapsed emission. `checkpoint()` updates the stored categories permissionlessly. This is a timing distinction, not additional funding or a second obligation.

A configured amount reserves `U` without any running segment. Starting records the current timestamp. A running segment with budget `B`, duration `D`, start `t0`, and cumulative released `E` has:

```
cumulative = floor(B * min(now - t0, D) / D)
due = cumulative - E
```

At the end, exactly `B` has left `U`. This avoids truncating a per-second integer rate and stranding a remainder. No cron/keeper is required: user or owner calls checkpoint on demand; the view projects results between calls.

If `S == 0`, `due` moves from `U` to `F`; `skippedRewards` is informational, not another reserve. Otherwise `due` moves from `U` to `L`, and the global index increases by `floor(due * 10^36 / S)`. Saved per-user indices are reward debt. Settling uses full-precision division plus `mulmod` to preserve each user's fractional base-unit credit. This prevents repeated claims or partial share changes from repeatedly discarding their fraction.

A full personal exit settles rewards **before** burning shares. Integer credits persist indefinitely, and the sub-base-unit fraction is explicitly discarded and emitted. While others remain, unresolved dust stays conservatively reserved in `L`. When `S` reaches zero, all former active accounts have settled; `L - C` is then provably unclaimable. Only that amount moves to `F` and increments informational `releasedRewardDust`. Old integer credits remain backed by `C = L`, including across future deposits and epochs. No list or user loop is needed.

Every new segment must satisfy `budget <= (type(uint256).max - rewardPerShare) / 10^36`. This derived representability limit keeps the index safe even if withdrawals later leave one share quantum. It is a raw-unit limit (roughly 1.1579e41 initially), not a chosen economic allocation; unusually high-decimal reward tokens must account for this finite lifetime index capacity. Oversized schedules revert before starting, leaving funds recoverable.

Continuing/restarting/configuring first checkpoints the old segment. Only `F + U` is available for the replacement budget; `L` never enters that calculation. A Continue preserves the epoch ID and its original start; its new remaining segment starts now. A Restart creates a new ID and start. Neither rewrites any user's saved index or credit. Top-up funding remains `F` until an explicit allocation. Cancellation returns only future `U` to `F` after checkpointing.

## Native ETH and Treasury

Native balance must cover `A`; forced ETH is excess only. Withdrawal effects and reward settlement occur before payment. The Treasury fee is received through its authenticated native entry point. The user payment tries a native call with **50,000 gas**. On rejection or exhaustion, exactly the same amount is wrapped in canonical WETH and transferred to the **same** beneficiary. If wrapping or transfer fails, all state changes and the Treasury payment revert. There is no additional fallback fee.

Treasury receives ERC20 fees by pulling an exact temporary allowance from a registered farm. It measures actual receipt and records that amount. The farm checks its exact debit and clears the allowance. Native fees use actual `msg.value`. Treasury spending is bounded by `receivedFees - spentFees`; unsolicited tokens or forced ETH do not increase this allowance. Such Treasury donations remain unspendable by design. The Treasury never holds a mandate to withdraw farm principal or reward reserves.
