#!/usr/bin/env bash
# Deploy the foreclose-app as an Authority application with a guardian, a claim staging period and the ONLY
# withdrawal config that can pay the snapshot's accounts out: the USD withdrawal output builder of the
# network's token (created through UsdWithdrawalOutputBuilderFactory if it does not exist yet) and the accounts
# drive layout read from the snapshot itself. Wraps `cartesi-rollups-cli deploy application`.
#
# A well-formed but wrong withdrawal config deploys fine and makes funds unrecoverable after a foreclosure
# (config is immutable, foreclosure irreversible). So this script refuses to deploy when:
#   - RPC_URL is not the network's chain, or a contract of the network has no code;
#   - the snapshot's TRUSTED_ERC20_TOKEN / TRUSTED_ERC20_PORTAL are not the network's token / Erc20Portal;
#   - the snapshot has no 4 MiB "accounts" flash drive aligned to its size, or --accounts-drive-start-index
#     disagrees with it;
#   - the builder's token() is not the snapshot's token, or the builder is not the factory's CREATE2 output;
#   - after the deploy, the on-chain template hash / withdrawal config differ from what was intended.
#
# Usage:
#   scripts/deploy.sh --network NET --snapshot DIR --name NAME --guardian ADDR --claim-staging-period BLOCKS
#                     [--template-path PATH] [--epoch-length N] [--salt 0x<32 bytes>]
#                     [--builder-salt 0x<32 bytes>] [--accounts-drive-start-index N] [--record-dir DIR]
#                     [--check-only]
#   --snapshot       snapshot dir on THIS host (checked here)
#   --template-path  the same snapshot as the node/CLI sees it (default: --snapshot); the node loads it from there
#   --check-only     run every check (and print the config) without sending any transaction
# Env: RPC_URL, CARTESI_AUTH_PRIVATE_KEY (deployer = application owner = Authority owner/claimer), CARTESI_CLI.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

NETWORK= SNAPSHOT= NAME= GUARDIAN= STAGING= TEMPLATE_PATH= EPOCH_LENGTH=10 SALT= BUILDER_SALT=0x0000000000000000000000000000000000000000000000000000000000000000
WANT_IDX= RECORD_DIR="$PWD/deployments" CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --guardian) GUARDIAN="$2"; shift 2 ;;
    --claim-staging-period) STAGING="$2"; shift 2 ;;
    --template-path) TEMPLATE_PATH="$2"; shift 2 ;;
    --epoch-length) EPOCH_LENGTH="$2"; shift 2 ;;
    --salt) SALT="$2"; shift 2 ;;
    --builder-salt) BUILDER_SALT="$2"; shift 2 ;;
    --accounts-drive-start-index) WANT_IDX="$2"; shift 2 ;;
    --record-dir) RECORD_DIR="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done
for v in network:NETWORK snapshot:SNAPSHOT name:NAME guardian:GUARDIAN claim-staging-period:STAGING; do
  n="${v#*:}"; [ -n "${!n}" ] || die "missing --${v%%:*} (see --help)"
done
[ -f "$SNAPSHOT/config.json" ] && [ -f "$SNAPSHOT/hash_tree.sht" ] || die "$SNAPSHOT is not a cartesi-machine --store dir"
TEMPLATE_PATH="${TEMPLATE_PATH:-$SNAPSHOT}"
is_addr "$GUARDIAN" || die "--guardian must be a 0x address"
same_addr "$GUARDIAN" 0x0000000000000000000000000000000000000000 && die "--guardian must not be the zero address"
[[ "$STAGING" =~ ^[0-9]+$ ]] && [ "$STAGING" -gt 0 ] || die "--claim-staging-period must be > 0 blocks (it is the guardian's window to foreclose)"
[[ "$BUILDER_SALT" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "--builder-salt must be 32 bytes"
SALT="${SALT:-0x$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')}"

load_network "$NETWORK"
need_key "deployer"
DEPLOYER="$(signer)"

# --- chain: the network's contracts must exist ---
for c in INPUT_BOX ERC20_PORTAL USD_BUILDER_FACTORY SAFE_ERC20_TRANSFER SELF_HOSTED_APPLICATION_FACTORY AUTHORITY_FACTORY TOKEN; do
  has_code "${!c}" || die "$c ${!c} has no code on chain $CHAIN_ID"
done

# --- snapshot: token, portal, accounts drive ---
TPL_HASH="$(snapshot_hash "$SNAPSHOT")"
SNAP_TOKEN="$(snapshot_env "$SNAPSHOT" TRUSTED_ERC20_TOKEN)"
SNAP_PORTAL="$(snapshot_env "$SNAPSHOT" TRUSTED_ERC20_PORTAL)"
[ -n "$SNAP_TOKEN" ] || die "snapshot has no TRUSTED_ERC20_TOKEN: not a foreclose-app snapshot"
same_addr "$SNAP_TOKEN" "$TOKEN" || die "snapshot token $SNAP_TOKEN is not $NETWORK's $TOKEN_SYMBOL $TOKEN (build it with: make foreclose-app NETWORK=$NETWORK)"
same_addr "$SNAP_PORTAL" "$ERC20_PORTAL" || die "snapshot portal $SNAP_PORTAL is not $NETWORK's Erc20Portal $ERC20_PORTAL"

read -r DRIVE_START DRIVE_LEN <<<"$(snapshot_accounts_drive "$SNAPSHOT")"
[ -n "${DRIVE_START:-}" ] || die "snapshot has no flash drive labelled 'accounts'"
LOG2_DRIVE=$((5 + LOG2_LEAVES_PER_ACCOUNT + LOG2_MAX_NUM_OF_ACCOUNTS))
[ "$DRIVE_LEN" -eq $((1 << LOG2_DRIVE)) ] || die "accounts drive length $DRIVE_LEN != 2^$LOG2_DRIVE (32-byte accounts x 2^$LOG2_MAX_NUM_OF_ACCOUNTS)"
[ $((DRIVE_START % DRIVE_LEN)) -eq 0 ] || die "accounts drive start $DRIVE_START is not aligned to its length"
IDX=$((DRIVE_START >> LOG2_DRIVE))
if [ -n "$WANT_IDX" ] && [ "$WANT_IDX" != "$IDX" ]; then
  die "--accounts-drive-start-index $WANT_IDX does not match the template's accounts drive (start $(printf 0x%x "$DRIVE_START") -> index $IDX)"
fi
REC_HASH="$(awk -v n="foreclose-app-$NETWORK" '$1 == n {print $2}' "$QA_ROOT/hashes.txt")"
if [ "$TPL_HASH" = "$REC_HASH" ]; then HASH_NOTE="= recorded build foreclose-app-$NETWORK"; else HASH_NOTE="NOT the recorded build ($REC_HASH)"; fi

# --- withdrawal output builder: the factory's USD builder for this token ---
SAFE="$(call "$USD_BUILDER_FACTORY" 'getSafeErc20Transfer()(address)')"
same_addr "$SAFE" "$SAFE_ERC20_TRANSFER" || die "factory uses SafeErc20Transfer $SAFE, expected $SAFE_ERC20_TRANSFER"
BUILDER="$(call "$USD_BUILDER_FACTORY" 'calculateUsdWithdrawalOutputBuilderAddress(address,bytes32)(address)' "$TOKEN" "$BUILDER_SALT")"
BUILDER_NEW=0
has_code "$BUILDER" || BUILDER_NEW=1

cat >&2 <<EOF
[qa-apps] deploy plan
  network            $NETWORK (chain $CHAIN_ID)
  deployer           $DEPLOYER  (application owner, Authority owner and claimer)
  application name   $NAME
  template           $TEMPLATE_PATH
  template hash      $TPL_HASH  ($HASH_NOTE)
  token in snapshot  $SNAP_TOKEN ($TOKEN_SYMBOL), portal $SNAP_PORTAL
  epoch length       $EPOCH_LENGTH blocks, claim staging period $STAGING blocks
  guardian           $GUARDIAN
  accounts drive     start $(printf 0x%x "$DRIVE_START"), length $DRIVE_LEN -> accounts_drive_start_index $IDX
  log2 leaves/acct   $LOG2_LEAVES_PER_ACCOUNT, log2 max accounts $LOG2_MAX_NUM_OF_ACCOUNTS
  withdrawal builder $BUILDER (UsdWithdrawalOutputBuilder for $TOKEN, salt $BUILDER_SALT)$([ "$BUILDER_NEW" = 1 ] && echo ' -- will be created')
EOF
[ "$CHECK_ONLY" = 1 ] && { log "check-only: all checks passed, nothing sent"; exit 0; }

if [ "$BUILDER_NEW" = 1 ]; then
  log "creating the USD withdrawal output builder through the factory"
  send "$USD_BUILDER_FACTORY" 'newUsdWithdrawalOutputBuilder(address,bytes32)' "$TOKEN" "$BUILDER_SALT" >/dev/null
  has_code "$BUILDER" || die "builder $BUILDER still has no code after creation"
fi
BTOKEN="$(call "$BUILDER" 'token()(address)')"
same_addr "$BTOKEN" "$SNAP_TOKEN" || die "builder $BUILDER pays $BTOKEN, but the snapshot holds $SNAP_TOKEN"

WC="$(jq -cn --arg g "$GUARDIAN" --arg b "$BUILDER" --argjson l "$LOG2_LEAVES_PER_ACCOUNT" \
  --argjson m "$LOG2_MAX_NUM_OF_ACCOUNTS" --argjson i "$IDX" \
  '{guardian:$g, log2_leaves_per_account:$l, log2_max_num_of_accounts:$m, accounts_drive_start_index:$i, withdrawal_output_builder:$b}')"
log "cartesi-rollups-cli deploy application $NAME $TEMPLATE_PATH --withdrawal-config '$WC'"
# shellcheck disable=SC2086
OUT_JSON="$($CARTESI_CLI deploy application "$NAME" "$TEMPLATE_PATH" --epoch-length "$EPOCH_LENGTH" \
  --claim-staging-period "$STAGING" --withdrawal-config "$WC" --salt "$SALT" --json)" || die "deploy application failed"
OUT_JSON="${OUT_JSON#"${OUT_JSON%%\{*}"}"   # drop anything printed before the JSON object
APP="$(jq -r '.iapplication_address // .application_address // empty' <<<"$OUT_JSON")"
CONSENSUS="$(jq -r '.iconsensus_address // .consensus_address // empty' <<<"$OUT_JSON")"
is_addr "$APP" || die "could not read the application address from: $OUT_JSON"

# --- post-deploy: what is on chain must be exactly what was intended ---
ONCHAIN_HASH="$(call "$APP" 'getTemplateHash()(bytes32)')"
[ "$ONCHAIN_HASH" = "$TPL_HASH" ] || die "on-chain template hash $ONCHAIN_HASH != snapshot $TPL_HASH (app $APP)"
read -r g l m i b <<<"$(call "$APP" 'getWithdrawalConfig()((address,uint8,uint8,uint64,address))' | tr -d '()' | tr ',' ' ')"
same_addr "$g" "$GUARDIAN" && [ "$l" = "$LOG2_LEAVES_PER_ACCOUNT" ] && [ "$m" = "$LOG2_MAX_NUM_OF_ACCOUNTS" ] \
  && [ "$i" = "$IDX" ] && same_addr "$b" "$BUILDER" || die "on-chain withdrawal config ($g,$l,$m,$i,$b) differs from the intended one"

mkdir -p "$RECORD_DIR"
REC="$RECORD_DIR/$NETWORK-$NAME.json"
jq -n --arg network "$NETWORK" --arg chain_id "$CHAIN_ID" --arg name "$NAME" --arg application "$APP" \
  --arg consensus "$CONSENSUS" --arg template_path "$TEMPLATE_PATH" --arg template_hash "$TPL_HASH" \
  --arg token "$TOKEN" --arg guardian "$GUARDIAN" --arg builder "$BUILDER" --arg deployer "$DEPLOYER" \
  --argjson accounts_drive_start_index "$IDX" --argjson log2_leaves_per_account "$LOG2_LEAVES_PER_ACCOUNT" \
  --argjson log2_max_num_of_accounts "$LOG2_MAX_NUM_OF_ACCOUNTS" --argjson epoch_length "$EPOCH_LENGTH" \
  --argjson claim_staging_period "$STAGING" '$ARGS.named' > "$REC"
log "deployed $NAME = $APP (consensus $CONSENSUS); on-chain template hash and withdrawal config verified"
log "deployment record: $REC"
cat "$REC"
