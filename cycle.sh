#!/usr/bin/env bash
# DEX.DO Season 1 — single-cycle auto-buyer for GitHub Actions
# Each run: deploy PN → fund → find ask → buy → close → withdraw → commit state
# Exits 0 on success, 1 on transient failure (retry next cron), 2 on hard failure
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/tvm-cli:$PATH"
export DEXDO_PN_POOL="${PN_POOL:-/tmp/pn_pool.json}"

WALLET_ADDR="${WALLET_ADDR:?}"
WALLET_SEED_FILE="${WALLET_SEED_FILE:?}"
DEST_WALLET="${DEST_WALLET:?}"
ENDPOINT="https://shellnet.ackinacki.org"
GIVER="1111111111111111111111111111111111111111111111111111111111111111"
CONTRACTS_DIR="${CONTRACTS_DIR:-contracts}"
LOG_FILE="${LOG_FILE:-/tmp/cycle.log}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"; }

# ---------- Setup ----------
setup() {
  log "=== setup ==="
  cd /tmp && mkdir -p dexdo-work && cd dexdo-work
  CONTRACTS_DIR="/tmp/dexdo-work/contracts"
  mkdir -p "$CONTRACTS_DIR"

  # Install dexdo if not cached
  if ! command -v dexdo >/dev/null 2>&1; then
    log "installing dexdo..."
    curl -fsSL https://github.com/gosh-sh/dexdo-cli/releases/latest/download/install.sh | sh 2>&1 | tail -3
  fi

  # Install tvm-cli if not cached
  if ! command -v tvm-cli >/dev/null 2>&1; then
    log "installing tvm-cli..."
    mkdir -p /tmp/tvm-cli
    curl -fsSL -o /tmp/tvm-cli.tar.gz \
      "https://github.com/tvmlabs/tvm-sdk/releases/latest/download/tvm-cli-3.0.4.an-linux-musl-amd64.tar.gz"
    tar -xzf /tmp/tvm-cli.tar.gz -C /tmp/tvm-cli
    cp /tmp/tvm-cli/tvm-cli "$HOME/.local/bin/"
  fi

  # Download contracts manifest
  if [ ! -f "$CONTRACTS_DIR/deployed.shellnet.json" ]; then
    curl -fsSL https://raw.githubusercontent.com/gosh-sh/dexdo-cli/main/contracts/deployed.shellnet.json \
      -o "$CONTRACTS_DIR/deployed.shellnet.json"
  fi

  # Download ABIs
  mkdir -p /tmp/abi
  for f in GiverV3.abi.json InferenceOrderBook.abi.json; do
    [ -f "/tmp/abi/$f" ] && continue
    case "$f" in
      GiverV3*) url="https://raw.githubusercontent.com/ackinacki/ackinacki/main/contracts/giver/GiverV3.abi.json" ;;
      InferenceOrderBook*) url="https://raw.githubusercontent.com/gosh-sh/dexdo-cli/main/contracts/compiled_0.79.3/airegistry/InferenceOrderBook.abi.json" ;;
    esac
    curl -fsSL "$url" -o "/tmp/abi/$f"
  done

  dexdo --version
  tvm-cli --version 2>&1 | head -1
  log "setup OK"
}

# ---------- Deploy PN (with resume support) ----------
deploy_pn() {
  local pool="$1" rec="$2"
  log "deploying PN -> $pool"
  rm -f /tmp/dexdo-note-deploy-wallet-*.lock

  # attempt 1 (fresh or resume)
  dexdo note deploy \
    --multisig-address "$WALLET_ADDR" \
    --multisig-seed-file "$WALLET_SEED_FILE" \
    --nominal N10000 --token-type nackl \
    --endpoint "$ENDPOINT" \
    --pool "$pool" --recovery "$rec" \
    > /tmp/deploy.log 2>&1
  if [ -f "$pool" ]; then return 0; fi

  log "first attempt did not finish; resuming..."
  sleep 5
  dexdo note deploy \
    --multisig-address "$WALLET_ADDR" \
    --multisig-seed-file "$WALLET_SEED_FILE" \
    --nominal N10000 --token-type nackl \
    --endpoint "$ENDPOINT" \
    --pool "$pool" --recovery "$rec" \
    >> /tmp/deploy.log 2>&1
  if [ -f "$pool" ]; then return 0; fi

  log "deploy FAILED"
  tail -5 /tmp/deploy.log
  return 1
}

# ---------- Fund PN with SHELL via giver ----------
fund_pn() {
  local pn_addr="$1"
  log "funding $pn_addr with 1000 SHELL..."
  tvm-cli -u "$ENDPOINT" call "${GIVER}::${GIVER}" sendCurrency \
    "{\"dest\":\"$pn_addr\",\"value\":\"1000000000\",\"ecc\":{\"2\":\"1000000000000\"}}" \
    --abi /tmp/abi/GiverV3.abi.json 2>&1 | grep -E "aborted|exit_code" | head -1
  sleep 3
}

# ---------- Scan markets for active ask ----------
find_ask() {
  log "scanning markets for active ask..."
  dexdo market-data list --limit 200 2>/dev/null \
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
  log "  $(wc -l < /tmp/markets.txt) canonical markets"

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
    log "  FOUND: $mmodel (orderCount=$oc)"
    echo "$mmodel"
    return 0
  done < /tmp/markets.txt
  return 1
}

# ---------- Buy + close ----------
do_buy_and_close() {
  local pn_addr="$1" pn_key="$2" pool="$3" model="$4"
  log "buying: $model pn=$pn_addr"

  DEXDO_PN_POOL="$pool" dexdo buyer \
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
  setup

  local pool="/tmp/pn_pool.json" rec="/tmp/pn_pool.json.recovery.json"
  if ! deploy_pn "$pool" "$rec"; then
    log "deploy failed; aborting run (will retry next cron)"
    exit 1
  fi

  local pn_addr pn_key
  pn_addr=$(python3 -c "import json; print(json.load(open('$pool'))['notes'][-1]['address'])")
  pn_key=$(python3 -c "import json; print(json.load(open('$pool'))['notes'][-1]['owner_secret_key_hex'])")
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

  do_buy_and_close "$pn_addr" "$pn_key" "$pool" "$model"
  do_withdraw "$pn_addr" "$pn_key"

  # final wallet balance
  log "=== final wallet balance ==="
  tvm-cli -u "$ENDPOINT" account "${DEST_WALLET#0:}::${DEST_WALLET#0:}" 2>/dev/null \
    | grep -E "balance|ecc|acc_type" | head -5 | tee -a "$LOG_FILE"
  log "=== cycle done (with buy) ==="
}

main "$@"
