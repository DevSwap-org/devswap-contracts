# DevSwap Contracts

Solidity smart contracts powering [**DevSwap**](https://devswap.pro) — an on-chain freelance marketplace on **BNB Smart Chain**. Funds are locked in USDT and released by the contract on the client's approval. Published for **transparency, verification, and audit**.

## Contracts (`src/`)

| Contract | Purpose |
|---|---|
| `DevSwapEscrowV2_6.sol` | **Current.** V2.6 milestone escrow with symmetric 3 % dispute bond and 4-way resolution split (50 / 35 / 10 / 5). |
| `DevSwapEscrowV2_4.sol` | Earlier — V2.4 introduced the staked 3-arbiter panel + pull-payment claims. Superseded by V2.6. |
| `DevSwapEscrowV2_1.sol` | Earlier — V2.1 milestone jobs + arbiter-registry hardening. Superseded. |
| `DevSwapEscrow.sol` | V1 task lifecycle (create → accept → submit → release / cancel / dispute) + separated buyback-and-burn. Superseded. |
| `DevSwapArbiterPool.sol` | Staked arbiter pool — weighted-random panel selection, cooldown unstake, slashing on missed votes. |
| `DevSwapToken.sol` | `$DSWP` — ERC-20, `Capped` (100 M), `Burnable`, `Ownable2Step`. |

## Economics

On a normal release the locked USDT splits: **97 % developer · 1.5 % platform fee · 1.5 % buyback-and-burn** of `$DSWP` (total **3 %**). The 1.5 % burn calls `burn()` after a PancakeSwap V2 swap, isolated so a failed swap never blocks the developer's payout (deferred to a reserve for a later bulk burn).

On a dispute the symmetric **3 % bond** posted by both parties is split: **50 %** to the winner, **35 %** to the majority panel, **10 %** to buyback-burn, **5 %** to the platform.

## Security posture

- CEI + `ReentrancyGuard` + `SafeERC20` + `Ownable2Step` + `Pausable`.
- Tested with Foundry: unit + fuzz (10 k runs) + invariants + **mainnet-fork** (real PancakeSwap buyback). 400 + tests across 19 suites.
- Static analysis (Slither) clean of high / medium findings. Mythril symbolic execution wired as a CI hard gate.
- ⚠️ An independent third-party audit is required before any mainnet deployment with real funds.
- Report vulnerabilities per the org [SECURITY policy](https://github.com/DevSwap-org/.github/blob/main/SECURITY.md) — **security@devswap.pro**, not via public issues.

## Build & test

```bash
forge build --sizes
forge test -vvv
FOUNDRY_PROFILE=ci forge test --fuzz-runs 10000   # heavy fuzz
forge test --match-test invariant_                # invariants
```

Toolchain: Foundry · Solidity `0.8.34` · `evm_version = shanghai` (BSC) · OpenZeppelin v5 (vendored under `lib/`).

## Network notes

- **USDT on BSC has 18 decimals** (≠ Ethereum's 6).
- BSC mainnet `chainId 56` · testnet `chainId 97`.
- Live on **testnet** today; addresses are published in the dApp and verified on BscScan.

## Documentation

Full protocol documentation: **<https://docs.devswap.pro>** (source: [`DevSwap-org/devswap-docs`](https://github.com/DevSwap-org/devswap-docs)).

## License

[MIT](LICENSE).
