# shellcheck shell=bash
# Shared helpers for scripts/*.sh. Source it; do not run it.
#
# Environment (never hard-code keys; see README "Keys"):
#   RPC_URL                    chain JSON-RPC endpoint as seen from THIS host (used by cast)       [required]
#   CARTESI_AUTH_PRIVATE_KEY   signer of the step being run (deployer / guardian / gas payer)    [required for txs]
#   CARTESI_CLI                command that runs cartesi-rollups-cli          (default: cartesi-rollups-cli)
#   CARTESI_MACHINE_TOOL       command that runs cartesi-rollups-machine-tool (default: cartesi-rollups-machine-tool)
# The two CARTESI_* commands must reach the same chain and the node database (they are the node's own tools,
# v2.0.0-alpha.13); they inherit CARTESI_AUTH_KIND / CARTESI_AUTH_PRIVATE_KEY from this environment. Example
# for a node running in Docker:
#   CARTESI_CLI="docker exec -i -e CARTESI_AUTH_KIND -e CARTESI_AUTH_PRIVATE_KEY <advancer-container> cartesi-rollups-cli"

set -euo pipefail

QA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARTESI_CLI="${CARTESI_CLI:-cartesi-rollups-cli}"
CARTESI_MACHINE_TOOL="${CARTESI_MACHINE_TOOL:-cartesi-rollups-machine-tool}"
export CARTESI_AUTH_KIND="${CARTESI_AUTH_KIND:-private_key}"

log() { printf '[qa-apps] %s\n' "$*" >&2; }
die() { printf '[qa-apps] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required (install it first)"; }

need cast
need jq

lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
same_addr() { [ "$(lc "$1")" = "$(lc "$2")" ]; }
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

# load_network NAME: sources networks/NAME.env and checks RPC_URL points at that chain.
load_network() {
  local f="$QA_ROOT/networks/$1.env"
  [ -f "$f" ] || die "unknown network '$1' (networks: $(cd "$QA_ROOT/networks" && ls | sed 's/\.env$//' | tr '\n' ' '))"
  # shellcheck disable=SC1090
  . "$f"
  [ -n "${RPC_URL:-}" ] || die "RPC_URL is not set"
  local id
  id="$(cast chain-id --rpc-url "$RPC_URL")" || die "cannot reach RPC_URL"
  [ "$id" = "$CHAIN_ID" ] || die "RPC_URL is chain $id, but network $NETWORK is chain $CHAIN_ID"
}

need_key() {
  [ -n "${CARTESI_AUTH_PRIVATE_KEY:-}" ] || die "CARTESI_AUTH_PRIVATE_KEY is not set (signer for this step: $1)"
  export CARTESI_AUTH_PRIVATE_KEY
}
signer() { cast wallet address --private-key "$CARTESI_AUTH_PRIVATE_KEY"; }

has_code() { [ "$(cast code "$1" --rpc-url "$RPC_URL")" != "0x" ]; }
call() { cast call "$@" --rpc-url "$RPC_URL"; }
first() { awk 'NR==1{print $1}'; }   # strip cast's "[1e6]" style annotations
send() {
  local out
  out="$(cast send "$@" --rpc-url "$RPC_URL" --private-key "$CARTESI_AUTH_PRIVATE_KEY" --json)" \
    || die "transaction failed: cast send $1 $2"
  [ "$(jq -r .status <<<"$out")" = "0x1" ] || die "transaction reverted: $(jq -r .transactionHash <<<"$out")"
  jq -r .transactionHash <<<"$out"
}
token_balance() { call "$TOKEN" 'balanceOf(address)(uint256)' "$1" | first; }

# --- snapshot inspection (host side: config.json + hash_tree.sht of a cartesi-machine --store dir) ---
snapshot_hash() { printf '0x%s\n' "$(od -An -tx1 -j96 -N32 "$1/hash_tree.sht" | tr -d ' \n')"; }
snapshot_env() {  # snapshot_env DIR VAR -> value exported by the machine init (cartesi-machine --env)
  jq -r '.config.dtb.init' "$1/config.json" | sed -n "s/^export $2=//p" | tail -1
}
# accounts drive (label "accounts") -> "start length"
snapshot_accounts_drive() {
  jq -r '.config.flash_drive[] | select(.label == "accounts") | "\(.start) \(.length)"' "$1/config.json"
}

# deployment record written by deploy.sh, read by emergency.sh / app.sh
record_get() { jq -r --arg k "$2" '.[$k] // empty' "$1"; }
