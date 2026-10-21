# Independent BLOOM V2.4 tests

These tests extend the accepted implementation and its original suite. Production
contracts, scripts, configuration, libraries and recorded dependency bytecode are
unchanged. All new fixtures and tests run offline.

## Coverage

| File | Additional checks |
| --- | --- |
| `NetworkInvariants.t.sol` | Stateful, four-actor sequences across BLOOM, sIMD, ETH and Treasury; measured custody ghosts; separate reward budgets; donations and recovery; partial/final exits; native/WETH payout; epoch transitions; pause/delist; Treasury spending; complete settlement after every campaign. |
| `EdgeProperties.t.sol` | 1,000 cases per property for decimals 0–36, donation isolation, repeated round trips and claim-frequency independence; one-unit dust; gift deposits; old claims across pool reset; timestamp overflow; rollback at epoch boundaries. |
| `AuthorityFailures.t.sol` | Unauthorized calls across all privileged farm operations; Factory/Treasury protection; selective renunciation across ownership transfer; failed CREATE2 registration and reusable salt; malformed initcode; event amounts and beneficiaries. |
| `TokenFailures.t.sol` | Optional, false and nonboolean ERC20 returns; measured net funding; zero and partially taxed receipts refused with `InexactTransfer`; transfer-tax failures; inbound/outbound callback protection; atomic claim, withdrawal, recovery and Treasury spending. |
| `IntegrationFailures.t.sol` | Dependency identity/metadata/chain checks at registration and again at activation; pause (not delisting) gates both sIMD inputs; WETH/IMD/sIMD/Treasury recipients refused; paused official vault; sIMD rounding to zero farm shares; preexisting IMD donation isolation; independent farm budgets; failed ETH fallback with earned rewards; native callback/recovery/Treasury failures. |

## Stateful properties and inputs

The handler selects only 16 explicit action selectors. Inputs are bounded; expected
zero-share deposits are checked explicitly, and unexpected reverts fail the run.
Inline configuration specifies 256 runs of 96 actions. Each run starts with two
funded positions and an active reward epoch in every farm, so solvency checks do
not pass solely because all farms stayed empty. A deterministic handler scenario
also exercises fallback, claims and all donation/recovery branches.

The independent transfer counters constrain:

- Deposits = remaining backing + actual user withdrawals + actual Treasury fees.
- Net reward funding = reserved rewards + actual claims + actual recoveries.
- Custody = backing + reward reserves (where applicable) + unrecovered donations.
- Treasury custody + actual spending = received fees + unsolicited donations.
- Summed actor shares/credits = the corresponding aggregate supply/liability.
- Pending claims fit within earned and scheduled funding; fractions remain bounded.
- Temporary Treasury and IMD staking approvals are cleared after each operation.
- WETH backing equals measured fallback payouts and no WETH remains at the ETH farm.

After every campaign, deposits are paused and assets delisted. Delisting alone does not stop deposits into an active farm; the handler deposits while delisted and asserts paused deposits revert. All four actors
withdraw every share, future rewards are cancelled, all earned claims are paid,
free funds are recovered and spendable Treasury fees are spent. No principal,
shares, integer credits or reward obligations may remain. Donations remain isolated.

The repeated-round-trip property excludes intervening withdrawals by other users;
it does not reject the explicitly accepted self-benefit or fee-sniping economics.
The claim-frequency comparison uses a share supply dividing reward precision
exactly, separating persistent user fractions from documented global-index dust.

## Reproduction and limits

```sh
forge build
FOUNDRY_FUZZ_SEED=0xa2dd4bc91022fec0027b6a9355476a6e97def148369ce70d30c412c8b4c5dfc7 forge test
```

IMD, sIMD and WETH integration uses the existing recorded runtime fixtures in
synthetic local state. It executes their actual conversion, transfer, hold and
wrapping code, but is not a mainnet fork or a fresh on-chain verification. Pausing
the external vault and mocking a WETH transfer failure are explicit fault
injections, not assertions that these changes are possible on the live contracts.

Live-state integration and activation checks against the real Job 2 BLOOM token
remain deployment dependencies. This test assignment sends no transactions and
makes no deployment claims. No new dependency installation is required.
