# DevSwap Contracts

Solidity smart contracts powering [**DevSwap**](https://devswap.pro) — a non-custodial protocol for
on-chain software-services settlement on **BNB Smart Chain**. A client locks the budget in **USDT**;
the **smart contract** releases it to the developer on the client's explicit approval, or via
deterministic on-chain dispute and timeout rules. Published for **transparency, verification, and audit**.

## Contracts (`src/`)

| Contract | Purpose |
|---|---|
| `DevSwapEscrow.sol` | **Escrow V1** — task lifecycle (create → accept → submit → release / cancel / dispute) with a **separated** buyback-and-burn so a failed market swap never blocks the developer payout. |
| `DevSwapEscrowV2_1.sol` | **Escrow V2.1** — milestone jobs + arbiter-registry hardening over V1. |
| `DevSwapToken.sol` | `$DSWP` — ERC-20, `Capped` (100 M), `Burnable`, `Ownable2Step`. Utility token only. |
| `interfaces/IERC20Burnable.sol`, `interfaces/IPancakeRouter02.sol` | Minimal interfaces (burn + PancakeSwap V2 router). |

> **Versioning note.** This repository tracks the open-sourced escrow series (V1 + V2.1). The live
> protocol may run a later revision; current deployed addresses are shown in the dApp and verified on
> BscScan. Newer contract revisions are published here only after their review gates complete.

## Economics

On a normal release the locked USDT splits **97 % developer · 1.5 % platform · 1.5 % buyback-and-burn**
of `$DSWP` (total **3 %**; the 97 % developer floor and 3 % ceiling are fixed in bytecode). The 1.5 %
burn calls `burn()` after a PancakeSwap V2 swap, isolated so a failed swap never blocks payout
(deferred to a reserve for a later bulk burn). Disputes are resolved by an on-chain arbiter process.

## Security posture

- CEI + `ReentrancyGuard` + `SafeERC20` + `Ownable2Step` + `Pausable`.
- Foundry test suite: unit + fuzz (10 k runs) + invariants + **mainnet-fork** (real PancakeSwap buyback), across **9 test suites**.
- Static analysis (Slither) clean of high / medium findings; Mythril symbolic execution wired as a CI gate (CodeQL on JS tooling).
- ⚠️ An independent third-party audit is required before any mainnet deployment that handles real funds.
- Report vulnerabilities privately per the org [SECURITY policy](https://github.com/DevSwap-org/.github/blob/main/SECURITY.md) — **security@devswap.pro**, never via public issues.

## Build & test

```bash
forge build --sizes
forge test -vvv
FOUNDRY_PROFILE=ci forge test --fuzz-runs 10000   # heavy fuzz
forge test --match-test invariant_                # invariants
```

Toolchain: Foundry · Solidity `0.8.24` · `evm_version = shanghai` (BSC) · OpenZeppelin v5 (vendored under `lib/`).

## Network notes

- **USDT on BSC has 18 decimals** (≠ Ethereum's 6).
- BSC mainnet `chainId 56` · testnet `chainId 97`.
- Live on **testnet** today; deployed addresses are published in the dApp and verified on BscScan.

## Documentation

Full protocol documentation: **<https://devswap.pro>** (source: [`DevSwap-org/devswap-docs`](https://github.com/DevSwap-org/devswap-docs)).

## License

[MIT](LICENSE).
