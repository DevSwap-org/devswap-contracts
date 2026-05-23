# DevSwap Contracts

Solidity smart contracts powering [**DevSwap**](https://devswap.pro) — an on‑chain freelance
marketplace on **BNB Smart Chain**. Funds are locked in USDT and released by the contract on the
client's approval. Published for **transparency, verification, and audit**.

## Contracts (`src/`)
| Contract | Purpose |
|---|---|
| `DevSwapEscrow.sol` | V1 task lifecycle (create → accept → submit → release/cancel/dispute) + separated buyback‑and‑burn. |
| `DevSwapEscrowV2_1.sol` | V2.1 milestone jobs + arbiter registry hardening. |
| `DevSwapToken.sol` | `$DSWP` — ERC20, Capped (100M), Burnable, `Ownable2Step`. |

## Economics
On release the locked USDT splits: **97%** developer · **1.5%** platform fee · **1.5%** buyback‑and‑burn
of `$DSWP` (total **3%**). The 1.5% burn uses `burn()` (PancakeSwap V2 swap), isolated so a failed swap
never blocks the developer's payout (deferred to a reserve for a later bulk burn).

## Security posture
- CEI + `ReentrancyGuard` + `SafeERC20` + `Ownable2Step` + `Pausable`.
- Tested with Foundry: unit + fuzz (10k runs) + invariants + **mainnet‑fork** (real PancakeSwap buyback).
- Static analysis (slither) clean of high/medium findings.
- ⚠️ An independent third‑party audit is required before any mainnet deployment with real funds.
- Report vulnerabilities per the org [SECURITY policy](https://github.com/DevSwap-org/.github/blob/main/SECURITY.md) — **security@devswap.pro**, not public issues.

## Build & test
```bash
forge build --sizes
forge test -vvv
FOUNDRY_PROFILE=ci forge test --fuzz-runs 10000   # heavy fuzz
forge test --match-test invariant_                 # invariants
```
Toolchain: Foundry · Solidity `0.8.24` · `evm_version = shanghai` (BSC) · OpenZeppelin v5 (vendored in `lib/`).

## Network notes
- **USDT on BSC has 18 decimals** (≠ Ethereum's 6).
- BSC mainnet `chainId 56` · testnet `chainId 97`.
- Live on **testnet** today; addresses are published in the dApp and verified on BscScan.

## License
[MIT](LICENSE).
