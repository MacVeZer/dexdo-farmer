# dexdo-farmer

Automatic DEX.DO Season 1 inference-market buyer running on GitHub Actions cron.

## What it does

Every 10 minutes, GitHub Actions triggers `cycle.sh`, which:
1. Installs `dexdo` CLI + `tvm-cli` (cached)
2. Deploys a fresh `PrivateNote` funded from `UpdateCustodianMultisig`
3. Funds the PN with 1000 SHELL via the public giver
4. Scans all active inference markets for a live ask
5. Buys 2 ticks, sends one chat request, closes the deal
6. Withdraws the PN balance to the registered wallet (triggers Season 1 points credit)
7. Commits the cycle log to this repo for audit

## Architecture

```
GitHub Actions cron (every 10 min)
  → checkout repo
  → restore tool cache (dexdo, tvm-cli)
  → run cycle.sh (single cycle, ~6 min)
  → commit log
```

Public repo = unlimited Actions minutes. `concurrency: dexdo-farmer-single`
prevents overlapping runs (wallet nonce lock).

## Secrets (set in repo settings)

| Secret | Value |
|---|---|
| `WALLET_ADDR` | `0:c06d32ac232485703ce360cf7d15529d6f060fc82d1be1551ca4b722bf4966f4` |
| `WALLET_SEED` | `prison upset lady foot sing hunt crazy asset melody jungle name trip fossil champion rather dose coffee couple loop repair dose worth neither fetch` |
| `DEST_WALLET` | `0:916c7235d75b49d7c4c11a49db10bccaf121bf9661ac2dffa7b1f459565ccbc4` |

## Manual trigger

```bash
gh workflow run farm.yml -R MacVeZer/dexdo-farmer
```

## Logs

All cycle logs land in `logs/` (last 50 kept).
