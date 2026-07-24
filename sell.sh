#!/usr/bin/env bash
# DEX.DO seller gateway — single-run for GitHub Actions
# Each run: ensure PN exists → provision a deal → launch seller gateway (10 min)
set +e
export PATH="$HOME/.local/bin:$PATH"

WALLET_ADDR="${WALLET_ADDR:?}"
WALLET_SEED_FILE="${WALLET_SEED_FILE:?}"
DEST_WALLET="${DEST_WALLET:?}"
ENDPOINT="https://shellnet.ackinacki.org"
GIVER="1111111111111111111111111111111111111111111111111111111111111111"
CONTRACTS_DIR="/tmp/contracts"
POOL="/tmp/seller_pn_pool.json"
RECOVERY="${POOL}.recovery.json"
MARKET="/tmp/market.json"
LOG_FILE="${LOG_FILE:-/tmp/seller.log}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"; }

# ---------- Setup ----------
setup() {
  log "=== setup ==="
  mkdir -p "$HOME/.local/bin" "$CONTRACTS_DIR" /tmp/abi /tmp/seller
  rm -f /tmp/dexdo-note-deploy-wallet-*.lock

  if ! command -v dexdo >/dev/null 2>&1; then
    log "installing dexdo..."
    curl -fsSL https://github.com/gosh-sh/dexdo-cli/releases/latest/download/install.sh | sh 2>&1 | tail -3
  fi
  if ! command -v tvm-cli >/dev/null 2>&1; then
    log "installing tvm-cli..."
    mkdir -p /tmp/tvm-cli-dl
    curl -fsSL -o /tmp/tvm-cli.tar.gz \
      "https://github.com/tvmlabs/tvm-sdk/releases/download/v3.0.4.an/tvm-cli-3.0.4.an-linux-musl-amd64.tar.gz"
    tar -xzf /tmp/tvm-cli.tar.gz -C /tmp/tvm-cli-dl
    cp /tmp/tvm-cli-dl/tvm-cli "$HOME/.local/bin/"
    chmod +x "$HOME/.local/bin/tvm-cli"
  fi

  [ -f "$CONTRACTS_DIR/deployed.shellnet.json" ] || \
    curl -fsSL https://raw.githubusercontent.com/gosh-sh/dexdo-cli/main/contracts/deployed.shellnet.json \
      -o "$CONTRACTS_DIR/deployed.shellnet.json"

  for f in GiverV3.abi.json InferenceOrderBook.abi.json PrivateNote.abi.json; do
    [ -f "/tmp/abi/$f" ] && continue
    case "$f" in
      GiverV3*) url="https://raw.githubusercontent.com/ackinacki/ackinacki/main/contracts/giver/GiverV3.abi.json" ;;
      InferenceOrderBook*) url="https://raw.githubusercontent.com/gosh-sh/dexdo-cli/main/contracts/compiled_0.79.3/airegistry/InferenceOrderBook.abi.json" ;;
      PrivateNote*) url="https://raw.githubusercontent.com/gosh-sh/dexdo-cli/main/contracts/compiled_0.79.3/dex/PrivateNote.abi.json" ;;
    esac
    curl -fsSL "$url" -o "/tmp/abi/$f"
  done

  log "setup OK"
}

# ---------- Ensure wallet funded ----------
ensure_wallet_funded() {
  local bare="${WALLET_ADDR#0:}"
  local out
  out=$(timeout 30 tvm-cli -u "$ENDPOINT" account "${bare}::${bare}" 2>/dev/null)
  [ -z "$out" ] && { log "WARN: cannot read wallet"; return 0; }
  local ecc_line
  ecc_line=$(echo "$out" | grep "^ecc:" | head -1)
  log "  wallet ecc: $ecc_line"
  local nackl shell vmshell
  nackl=$(echo "$ecc_line" | python3 -c "import re,sys; m=re.search(r'\"1\":\"([0-9]+)\"', sys.stdin.read()); print(m.group(1) if m else '0')" 2>/dev/null)
  shell=$(echo "$ecc_line" | python3 -c "import re,sys; m=re.search(r'\"2\":\"([0-9]+)\"', sys.stdin.read()); print(m.group(1) if m else '0')" 2>/dev/null)
  vmshell=$(echo "$out" | grep "^balance:" | grep -oE "[0-9]+" | head -1)
  [ -z "$vmshell" ] && vmshell=0
  log "  NACKL=$nackl SHELL=$shell VMSHELL=$vmshell"

  local need_n=0 need_s=0 need_v=0
  [ "$nackl" -lt 20000000000000 ] && need_n=50000
  [ "$shell" -lt 5000000000000 ] && need_s=5000
  [ "$vmshell" -lt 50000000000 ] && need_v=500

  if [ $need_n -gt 0 ] || [ $need_s -gt 0 ] || [ $need_v -gt 0 ]; then
    log "  topping up: N=$need_n S=$need_s V=$need_v"
    local ecc="{}" val="0"
    if [ $need_n -gt 0 ] && [ $need_s -gt 0 ]; then
      ecc="{\"1\":\"$((need_n*1000000000))\",\"2\":\"$((need_s*1000000000))\"}"
    elif [ $need_n -gt 0 ]; then
      ecc="{\"1\":\"$((need_n*1000000000))\"}"
    elif [ $need_s -gt 0 ]; then
      ecc="{\"2\":\"$((need_s*1000000000))\"}"
    fi
    [ $need_v -gt 0 ] && val="$((need_v*1000000000))"
    timeout 30 tvm-cli -u "$ENDPOINT" call "${GIVER}::${GIVER}" sendCurrency \
      "{\"dest\":\"$WALLET_ADDR\",\"value\":\"$val\",\"ecc\":$ecc}" \
      --abi /tmp/abi/GiverV3.abi.json 2>&1 | grep -E "aborted|exit_code" | head -1 >> "$LOG_FILE"
    sleep 3
  fi
}

# ---------- Ensure seller PN exists ----------
ensure_seller_pn() {
  if [ -f "$POOL" ]; then
    log "seller PN pool already exists"
    return 0
  fi

  log "deploying seller PN..."
  rm -f /tmp/dexdo-note-deploy-wallet-*.lock
  timeout 480 dexdo note deploy \
    --multisig-address "$WALLET_ADDR" \
    --multisig-seed-file "$WALLET_SEED_FILE" \
    --nominal N1000 --token-type shell \
    --endpoint "$ENDPOINT" \
    --pool "$POOL" --recovery "$RECOVERY" \
    > /tmp/seller_deploy.log 2>&1

  if [ -f "$POOL" ]; then
    log "  PN deployed"
    return 0
  fi

  # Try to finalize from recovery
  if [ -f "$RECOVERY" ]; then
    local pn_addr
    pn_addr=$(python3 -c "import json; d=json.load(open('$RECOVERY')); print(d.get('pn_address') or '')" 2>/dev/null)
    if [ -n "$pn_addr" ]; then
      log "  PN on-chain ($pn_addr), finalizing pool"
      python3 << EOF
import json
d = json.load(open('$RECOVERY'))
pool = {"version":1,"notes":[{
  "address": d["pn_address"],
  "owner_public_key_hex": d["owner_public_key_hex"],
  "owner_secret_key_hex": d["owner_secret_key_hex"],
  "nominal": d["nominal"],
  "token_type": d["token_type"],
  "raw_value": d["raw_value"],
  "ecc_shell_deposit": d["ecc_shell_deposit"],
  "funding_multisig_address": d["funding_multisig_address"],
  "endpoint": d["endpoint"],
}]}
with open('$POOL', 'w') as f: json.dump(pool, f, indent=2)
EOF
      [ -f "$POOL" ] && return 0
    fi
  fi

  log "  deploy FAILED"
  tail -5 /tmp/seller_deploy.log >> "$LOG_FILE"
  return 1
}

# ---------- Fund PN via giver ----------
fund_pn() {
  local pn_addr="$1"
  log "funding PN $pn_addr with 100 SHELL..."
  timeout 30 tvm-cli -u "$ENDPOINT" call "${GIVER}::${GIVER}" sendCurrency \
    "{\"dest\":\"$pn_addr\",\"value\":\"1000000000\",\"ecc\":{\"2\":\"100000000000\"}}" \
    --abi /tmp/abi/GiverV3.abi.json 2>&1 | grep -E "aborted|exit_code" | head -1 >> "$LOG_FILE"
  sleep 3
}

# ---------- Provision a deal ----------
provision_deal() {
  local pn_addr="$1" pn_key="$2" nonce="$3"
  log "provisioning deal (nonce=$nonce)..."
  timeout 180 dexdo provision \
    --note-addr "$pn_addr" \
    --note-key <(echo "$pn_key") \
    --frame-model "qwen--qwen3--32b" \
    --nonce "$nonce" \
    --price-per-tick 1 \
    --max-ticks 1024 \
    --deposit-shells 50 \
    --output "$MARKET" \
    --contracts "$CONTRACTS_DIR/deployed.shellnet.json" \
    > /tmp/provision.log 2>&1
  if [ -f "$MARKET" ]; then
    log "  deal provisioned: $(cat $MARKET | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["token_contract"])')"
    return 0
  fi
  log "  provision FAILED"
  tail -5 /tmp/provision.log >> "$LOG_FILE"
  return 1
}

# ---------- Write models.json ----------
write_models_json() {
  [ -f /tmp/seller/models.json ] && return 0
  cat > /tmp/seller/models.json << 'EOF'
{
  "models": {
    "qwen": {
      "frame_model": "qwen--qwen3--32b",
      "base_url": "https://openrouter.ai/api/v1",
      "served_model": "openai/gpt-oss-20b:free",
      "api_key_env": "OPENROUTER_API_KEY",
      "tokenizer_family": "qwen",
      "price_per_tick": 1000,
      "capabilities": { "logprobs": false }
    }
  }
}
EOF
}

# ---------- Main ----------
main() {
  : > "$LOG_FILE"
  setup
  ensure_wallet_funded

  if ! ensure_seller_pn; then
    log "no seller PN; aborting"
    exit 1
  fi

  local pn_addr pn_key
  pn_addr=$(python3 -c "import json; print(json.load(open('$POOL'))['notes'][-1]['address'])" 2>/dev/null)
  pn_key=$(python3 -c "import json; print(json.load(open('$POOL'))['notes'][-1]['owner_secret_key_hex'])" 2>/dev/null)
  log "seller PN: $pn_addr"

  # Fund PN if low (need at least 100 SHELL for provision + gas)
  local bal
  bal=$(timeout 30 dexdo note balance --note-addr "$pn_addr" --contracts "$CONTRACTS_DIR/deployed.shellnet.json" 2>/dev/null \
    | grep "SHELL ECC\[2\]:" | grep -oE "raw [0-9]+" | cut -d' ' -f2)
  log "PN SHELL raw=$bal"
  if [ -z "$bal" ] || [ "$bal" -lt 100000000000 ]; then
    fund_pn "$pn_addr"
  fi

  write_models_json

  # Use a fresh nonce each run (unique deals)
  local nonce
  nonce=$(date +%s)
  nonce=$((nonce % 1000000))
  log "using nonce=$nonce"

  if ! provision_deal "$pn_addr" "$pn_key" "$nonce"; then
    log "provision failed; aborting"
    exit 1
  fi

  # Launch seller gateway for 12 minutes
  log "launching seller gateway (12 min)..."
  DEXDO_PN_POOL="$POOL" timeout 720 dexdo seller \
    --market "$MARKET" \
    --model qwen \
    --models /tmp/seller/models.json \
    --note-addr "$pn_addr" \
    --note-key <(echo "$pn_key") \
    --gateway-listen 0.0.0.0:8443 \
    --contracts "$CONTRACTS_DIR/deployed.shellnet.json" \
    >> "$LOG_FILE" 2>&1
  log "seller gateway exited"

  # Withdraw remaining PN balance (only if no stream-lock)
  log "withdrawing seller PN -> $DEST_WALLET"
  timeout 90 dexdo note withdraw \
    --note-addr "$pn_addr" --note-key <(echo "$pn_key") \
    --to "$DEST_WALLET" \
    --contracts "$CONTRACTS_DIR/deployed.shellnet.json" 2>&1 | grep -E "submitted|Error|locked" | head -2 >> "$LOG_FILE"

  log "=== final wallet balance ==="
  tvm-cli -u "$ENDPOINT" account "${DEST_WALLET#0:}::${DEST_WALLET#0:}" 2>/dev/null | grep -E "balance|ecc" | head -3 >> "$LOG_FILE"
  log "=== DONE ==="
}

main "$@"
