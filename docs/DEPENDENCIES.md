# Vendored dependencies

No submodules, npm packages, compiler binaries, network fetches during tests, or external library links are required.

| Dependency | Pinned release | Local files | License |
|---|---|---|---|
| OpenZeppelin Contracts | `v5.1.0` | `lib/openzeppelin-contracts/contracts/` (only the imported transitive source closure) | `lib/openzeppelin-contracts/LICENSE` |
| forge-std | `v1.9.7` | `lib/forge-std/src/` | `lib/forge-std/LICENSE-MIT`, `LICENSE-APACHE` |

Archives were fetched from `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.1.0` and `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`. No `.git`, `.github`, environment files, or `node_modules` were imported. Dependencies are plain delivered files; building does not resolve tags or contact GitHub.

OpenZeppelin supplies full-precision `Math.mulDiv`, `SafeERC20.forceApprove`, `Ownable2Step`, and the shared reentrancy guard. The project's production logic does not use delegatecall, callcode, selfdestruct, proxies, or external linked libraries. Internal unused utility functions are not present in deployed application code.

Official IMD, sIMD and WETH source/ABI are recorded in `docs/evidence/` to support the integration review. Their original copyright/SPDX notices are preserved. The unmodified runtime fixtures in `test/fixtures/` are test data, not deployments or compiled replacements for those protocols. WETH's corresponding source and full GPL text are in its evidence JSON; IMD's verified entry source is marked UNLICENSED, and sIMD's is MIT. None of that source is imported into the production contracts.

The task's pinned protected checks and eth-security/eth-addresses references were read as requirements/background data. They are not copied into the deliverable and are not build dependencies. No prior BLOOM project code or deployment was used.
