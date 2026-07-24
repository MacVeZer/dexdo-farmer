#!/usr/bin/env bash
# DEX.DO Season 1 — single-cycle auto-buyer for GitHub Actions
# Each run: deploy PN → fund → find ask → buy → close → withdraw → commit log
# Robust against transient failures; uses dexdo's recovery state for resume
set +e  # NO set -e: we handle errors explicitly
export PATH="$HOME/.local/bin:$PATH"

WALLET_ADDR="${WALLET_ADDR:?}"
WALLET_SEED_FILE="${WALLET_SEED_FILE:?}"
DEST_WALLET="${DEST_WALLET:?}"
ENDPOINT="https://shellnet.ackinacki.org"
GIVER="1111111111111111111111111111111111111111111111111111111111111111"
CONTRACTS_DIR="/tmp/contracts"
LOG_FILE="${LOG_FILE:-/tmp/cycle.log}"
POOL="/tmp/pn_pool.json"
RECOVERY="${POOL}.recovery.json"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"; }

# ---------- Setup ----------
setup() {
  log "=== setup ==="
  mkdir -p "$HOME/.local/bin" "$CONTRACTS_DIR" /tmp/abi

  # CRITICAL: clear stale wallet lock from previous run
  rm -f /tmp/dexdo-note-deploy-wallet-*.lock

  # Install dexdo if missing
  if ! command -v dexdo >/dev/null 2>&1; then
    log "installing dexdo..."
    curl -fsSL https://github.com/gosh-sh/dexdo-cli/releases/latest/download/install.sh | sh 2>&1 | tail -3
  fi

  # Install tvm-cli if missing
  if ! command -v tvm-cli >/dev/null 2>&1; then
    log "installing tvm-cli..."
    mkdir -p /tmp/tvm-cli-dl
    curl -fsSL -o /tmp/tvm-cli.tar.gz \
      "https://github.com/tvmlabs/tvm-sdk/releases/download/v3.0.4.an/tvm-cli-3.0.4.an-linux-musl-amd64.tar.gz"
    tar -xzf /tmp/tvm-cli.tar.gz -C /tmp/tvm-cli-dl
    cp /tmp/tvm-cli-dl/tvm-cli "$HOME/.local/bin/"
    chmod +x "$HOME/.local/bin/tvm-cli"
  fi

  # Download contracts manifest
  if [ ! -f "$CONTRACTS_DIR/deployed.shellnet.json" ]; then
    curl -fsSL https://raw.githubusercontent.com/gosh-sh/dexdo-cli/main/contracts/deployed.shellnet.json \
      -o "$CONTRACTS_DIR/deployed.shellnet.json"
  fi

  # Download ABIs
  for f in GiverV3.abi.json InferenceOrderBook.abi.json; do
    [ -f "/tmp/abi/$f" ] && continue
    case "$f" in
      GiverV3*) url="https://raw.githubusercontent.com/ackinacki/ackinacki/main/contracts/giver/GiverV3.abi.json" ;;
      InferenceOrderBook*) url="https://raw.githubusercontent.com/gosh-sh/dexdo-cli/main/contracts/compiled_0.79.3/airegistry/InferenceOrderBook.abi.json" ;;
    esac
    curl -fsSL "$url" -o "/tmp/abi/$f"
  done

  log "tools: $(dexdo --version 2>&1), $(tvm-cli --version 2>&1 | head -1)"
  log "setup OK"
}

# ---------- Recovery helpers ----------
recovery_get() {
  [ -f "$RECOVERY" ] || return 0
  python3 -c "
import json, sys
try:
    d = json.load(open('$RECOVERY'))
    v = d.get('$1')
    if v is None or v == 'None' or v == 'null':
        print('')
    else:
        print(v)
except Exception:
    pass
" 2>/dev/null
}

finalize_pool_from_recovery() {
  [ -f "$RECOVERY" ] || return 1
  local pn_addr
  pn_addr=$(recovery_get pn_address)
  [ -z "$pn_addr" ] && return 1
  [ -f "$POOL" ] && return 0
  log "  finalizing pool.json from recovery state (pn=$pn_addr)"
  python3 << EOF
import json
d = json.load(open('$RECOVERY'))
pool = {
    "version": 1,
    "notes": [{
        "address": d["pn_address"],
        "owner_public_key_hex": d["owner_public_key_hex"],
        "owner_secret_key_hex": d["owner_secret_key_hex"],
        "nominal": d["nominal"],
        "token_type": d["token_type"],
        "raw_value": d["raw_value"],
        "ecc_shell_deposit": d["ecc_shell_deposit"],
        "funding_multisig_address": d["funding_multisig_address"],
        "endpoint": d["endpoint"],
        "deployed_at_unix": d.get("deployed_at_unix"),
        "deposit_identifier_hash": d.get("deposit_identifier_hash"),
    }]
}
with open('$POOL', 'w') as f:
    json.dump(pool, f, indent=2)
EOF
  [ -f "$POOL" ]
}

# ---------- Deploy PN (multi-attempt with smart recovery) ----------
deploy_pn() {
  log "deploying PN -> $POOL"
  rm -f /tmp/dexdo-note-deploy-wallet-*.lock

  if [ -f "$POOL" ]; then
    log "  pool already exists"
    return 0
  fi

  if [ -n "$(recovery_get pn_address)" ]; then
    log "  recovery has pn_address — finalizing pool"
    finalize_pool_from_recovery && return 0
  fi

  log "  attempt 1 (bounded 6 min)"
  timeout 360 dexdo note deploy \
    --multisig-address "$WALLET_ADDR" \
    --multisig-seed-file "$WALLET_SEED_FILE" \
    --nominal N10000 --token-type nackl \
    --endpoint "$ENDPOINT" \
    --pool "$POOL" --recovery "$RECOVERY" \
    > /tmp/deploy1.log 2>&1
  if [ -f "$POOL" ]; then log "  attempt 1 OK"; return 0; fi
  if [ -n "$(recovery_get pn_address)" ]; then
    log "  attempt 1: PN on-chain, finalizing"
    finalize_pool_from_recovery && return 0
  fi

  log "  attempt 2: resume (bounded 4 min)"
  rm -f /tmp/dexdo-note-deploy-wallet-*.lock
  sleep 3
  timeout 240 dexdo note deploy \
    --multisig-address "$WALLET_ADDR" \
    --multisig-seed-file "$WALLET_SEED_FILE" \
    --nominal N10000 --token-type nackl \
    --endpoint "$ENDPOINT" \
    --pool "$POOL" --recovery "$RECOVERY" \
    > /tmp/deploy2.log 2>&1
  if [ -f "$POOL" ]; then log "  attempt 2 OK"; return 0; fi
  if [ -n "$(recovery_get pn_address)" ]; then
    log "  attempt 2: PN on-chain, finalizing"
    finalize_pool_from_recovery && return 0
  fi

  log "  deploy FAILED (both attempts)"
  log "  --- deploy1 tail ---"
  tail -5 /tmp/deploy1.log >> "$LOG_FILE" 2>&1
  log "  --- deploy2 tail ---"
  tail -5 /tmp/deploy2.log >> "$LOG_FILE" 2>&1
  return 1
}

# ---------- Fund PN with SHELL via giver ----------
fund_pn() {
  local pn_addr="$1"
  log "funding $pn_addr with 1000 SHELL via giver..."
  timeout 30 tvm-cli -u "$ENDPOINT" call "${GIVER}::${GIVER}" sendCurrency \
    "{\"dest\":\"$pn_addr\",\"value\":\"1000000000\",\"ecc\":{\"2\":\"1000000000000\"}}" \
    --abi /tmp/abi/GiverV3.abi.json 2>&1 | grep -E "aborted|exit_code" | head -1 | tee -a "$LOG_FILE"
  sleep 3
}

# ---------- Find an active ask ----------
find_ask() {
  log "scanning markets for active ask..."
  timeout 30 dexdo market-data list --limit 200 2>/dev/null \
    | grep -E "^market address=" \
    | awk -F'[= ]' '{
        addr=""; model=""; status="";
        for(i=1;i<=NF;i++){
          if($(i-1)=="address") addr=$i;
          if($(i-1)=="model_ref") model=$i;
          if($(i-1)=="status") status=$i;
        }
        if(status=="TRADING" && model ~ /--.*--/) print addr, model
      }' > /tmp/markets.txt
  local mcount
  mcount=$(wc -l < /tmp/markets.txt 2>/dev/null || echo 0)
  log "  $mcount canonical markets"

  local scanned=0
  while IFS=' ' read -r maddr mmodel; do
    [ -z "$maddr" ] && continue
    scanned=$((scanned+1))
    [ $scanned -gt 40 ] && break
    local bare="${maddr#0:}"
    local out
    out=$(timeout 15 tvm-cli -u "$ENDPOINT" run --abi /tmp/abi/InferenceOrderBook.abi.json \
      "${bare}::${bare}" getBestBidAsk '{}' 2>/dev/null) || continue
    echo "$out" | grep -q '"hasAsk": true' || continue
    local stats oc
    stats=$(timeout 15 tvm-cli -u "$ENDPOINT" run --abi /tmp/abi/InferenceOrderBook.abi.json \
      "${bare}::${bare}" getStats '{}' 2>/dev/null) || continue
    oc=$(echo "$stats" | grep '"orderCount":' | grep -oE '"[0-9]+"' | tr -d '"')
    [ -z "$oc" ] && continue
    [ "$oc" = "0" ] && continue
    log "  FOUND ask: $mmodel (orderCount=$oc)"
    echo "$mmodel"
    return 0
  done < /tmp/markets.txt
  return 1
}

# ---------- Buy + close ----------
do_buy_and_close() {
  local pn_addr="$1" pn_key="$2" model="$3"
  log "buying: $model pn=$pn_addr"

  DEXDO_PN_POOL="$POOL" dexdo buyer \
    --note-addr "$pn_addr" \
    --note-key <(echo "$pn_key") \
    --frame-model "$model" --ticks 2 --max-price-per-tick 1000 \
    --local-listen 127.0.0.1:8080 \
    --continuity-mode on-demand --allow-unverified-model \
    --contracts "$CONTRACTS_DIR/deployed.shellnet.json" \
    > /tmp/buyer.log 2>&1 &
  local bpid=$!
  for i in 1 2 3 4 5 6 7 8; do
    sleep 4
    curl -s --max-time 2 http://127.0.0.1:8080/v1/models 2>/dev/null | grep -q "data" && break
    kill -0 $bpid 2>/dev/null || break
  done

  local resp
  resp=$(curl -sS --max-time 120 http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one short sentence about cats.\"}],\"stream\":false}" 2>&1)
  log "  resp: $(echo "$resp" | head -c 200)"

  local handle
  handle=$(grep "deal_handle=" /tmp/buyer.log | tail -1 | grep -oE "deal-[0-9a-f-]+" | head -1)
  log "  deal: ${handle:-none}"
  sleep 5

  if [ -n "$handle" ]; then
    timeout 60 dexdo close "$handle" --note-key <(echo "$pn_key") \
      --contracts "$CONTRACTS_DIR/deployed.shellnet.json" 2>&1 \
      | grep -E "action=|close submitted|Error" | head -2 | tee -a "$LOG_FILE"
  fi
  pkill -9 -f "dexdo buyer" 2>/dev/null
  sleep 2
}

# ---------- Withdraw ----------
do_withdraw() {
  local pn_addr="$1" pn_key="$2"
  log "withdrawing $pn_addr -> $DEST_WALLET"
  timeout 90 dexdo note withdraw \
    --note-addr "$pn_addr" --note-key <(echo "$pn_key") \
    --to "$DEST_WALLET" \
    --contracts "$CONTRACTS_DIR/deployed.shellnet.json" 2>&1 \
    | grep -E "submitted|Error|locked" | head -2 | tee -a "$LOG_FILE"
  sleep 3
}

# ---------- Main ----------
main() {
  : > "$LOG_FILE"
  setup

  # IMPORTANT: do NOT delete pool/recovery here. We rely on cross-run recovery state
  # when a deposit voucher was submitted but VoucherGenerated event hadn't arrived yet.
  # GitHub Actions cache /tmp/abi and /tmp/contracts but NOT /tmp/pn_pool* (they're
  # in /tmp which is fresh per run, EXCEPT when we explicitly cache them).

  # If pool file exists from a prior successful deploy in this same run, use it.
  # Otherwise, deploy_pn will check recovery state and resume if possible.

  if ! deploy_pn; then
    log "deploy failed; aborting (will retry next cron)"
    # salvage: if PN exists on-chain, withdraw it to dest wallet
    pn_addr=$(recovery_get pn_address)
    pn_key=$(recovery_get owner_secret_key_hex)
    if [ -n "$pn_addr" ] && [ -n "$pn_key" ]; then
      log "salvaging: withdrawing PN $pn_addr -> $DEST_WALLET"
      do_withdraw "$pn_addr" "$pn_key"
    fi
    exit 1
  fi

  # After successful deploy, clean up recovery state so next run starts fresh
  rm -f "$RECOVERY"

  local pn_addr pn_key
  pn_addr=$(python3 -c "import json; print(json.load(open('$POOL'))['notes'][-1]['address'])" 2>/dev/null)
  pn_key=$(python3 -c "import json; print(json.load(open('$POOL'))['notes'][-1]['owner_secret_key_hex'])" 2>/dev/null)
  if [ -z "$pn_addr" ] || [ -z "$pn_key" ]; then
    log "FATAL: pool has no note. Aborting."
    exit 1
  fi
  log "PN: $pn_addr"

  fund_pn "$pn_addr"

  local model
  model=$(find_ask)
  if [ -z "$model" ]; then
    log "no active asks; withdrawing PN unused"
    do_withdraw "$pn_addr" "$pn_key"
    log "=== cycle done (no ask) ==="
    exit 0
  fi

  do_buy_and_close "$pn_addr" "$pn_key" "$model"
  do_withdraw "$pn_addr" "$pn_key"

  log "=== final wallet balance ==="
  tvm-cli -u "$ENDPOINT" account "${DEST_WALLET#0:}::${DEST_WALLET#0:}" 2>/dev/null \
    | grep -E "balance|ecc" | head -3 | tee -a "$LOG_FILE"
  log "=== cycle done (with buy) ==="
}

main "$@"
