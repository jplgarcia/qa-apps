#!/usr/bin/env bash
# Normal (non-emergency) use of a foreclose-app deployment.
#
#   scripts/app.sh deposit            TARGET --amount BASE_UNITS [--mint]     signer = depositor
#   scripts/app.sh request-withdrawal TARGET --amount BASE_UNITS              signer = account owner
#   scripts/app.sh execute            TARGET --output-index N                 signer = any gas payer
#   scripts/app.sh balance            TARGET --account ADDR                   (inspect, no signer)
#
# TARGET = --deployment FILE (from scripts/deploy.sh) or --network NET --app 0xADDR.
# Amounts are token base units (USDC/TestUsdc: 6 decimals, 1 USDC = 1000000). The app accepts positive
# int64 amounts only. --mint calls TestUsdc.mint first (devnet only; on testnets get USDC from the Circle faucet).
# request-withdrawal sends InputBox.addInput(app, 0x01 || uint64be(amount)); the app debits the account and
# emits an ERC-20 transfer voucher, executable with `execute` once its epoch is CLAIM_ACCEPTED.
# Env: RPC_URL, CARTESI_AUTH_PRIVATE_KEY, CARTESI_CLI (execute, balance).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
CMD="${1:-}"; [ $# -gt 0 ] && shift
case "$CMD" in -h|--help|'') usage; exit 0 ;; esac
DEPLOYMENT='' NETWORK='' APP='' AMOUNT='' MINT=0 OUTPUT_INDEX='' ACCOUNT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --deployment) DEPLOYMENT="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --amount) AMOUNT="$2"; shift 2 ;;
    --mint) MINT=1; shift ;;
    --output-index) OUTPUT_INDEX="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done
if [ -n "$DEPLOYMENT" ]; then
  NETWORK="${NETWORK:-$(record_get "$DEPLOYMENT" network)}"; APP="${APP:-$(record_get "$DEPLOYMENT" application)}"
fi
[ -n "$NETWORK" ] && is_addr "${APP:-}" || die "give --deployment FILE or --network NET --app 0xADDR"
load_network "$NETWORK"
amount_ok() { [[ "${AMOUNT:-}" =~ ^[0-9]+$ ]] && [ "$AMOUNT" -gt 0 ] || die "--amount must be a positive integer (base units)"; }
input_index() { cast receipt "$1" --rpc-url "$RPC_URL" --json \
  | jq -r --arg ib "$(lc "$INPUT_BOX")" '[.logs[] | select((.address | ascii_downcase) == $ib)][0].topics[2]' | xargs cast to-dec; }

case "$CMD" in
  deposit)
    amount_ok; need_key "depositor"
    me="$(signer)"
    if [ "$MINT" = 1 ]; then
      [ "$NETWORK" = devnet ] || die "--mint only exists for the devnet TestUsdc"
      send "$TOKEN" 'mint(address,uint256)' "$me" "$AMOUNT" >/dev/null
    fi
    [ "$(token_balance "$me")" -ge "$AMOUNT" ] || die "$me has less than $AMOUNT $TOKEN_SYMBOL"
    send "$TOKEN" 'approve(address,uint256)' "$ERC20_PORTAL" "$AMOUNT" >/dev/null
    tx="$(send "$ERC20_PORTAL" 'depositErc20Tokens(address,address,uint256,bytes)' "$TOKEN" "$APP" "$AMOUNT" 0x)"
    echo "deposited $AMOUNT $TOKEN_SYMBOL from $me: tx $tx input_index $(input_index "$tx")" ;;
  request-withdrawal)
    amount_ok; need_key "account owner"
    tx="$(send "$INPUT_BOX" 'addInput(address,bytes)' "$APP" "$(printf '0x01%016x' "$AMOUNT")")"
    echo "withdrawal request of $AMOUNT from $(signer): tx $tx input_index $(input_index "$tx")" ;;
  execute)
    [[ "${OUTPUT_INDEX:-}" =~ ^[0-9]+$ ]] || die "--output-index N is required"
    need_key "gas payer"
    # shellcheck disable=SC2086
    $CARTESI_CLI execute "$APP" "$OUTPUT_INDEX" --yes --json ;;
  balance)
    is_addr "${ACCOUNT:-}" || die "--account 0xADDR is required"
    # shellcheck disable=SC2086
    out="$($CARTESI_CLI inspect "$APP" "balance $ACCOUNT")"
    p="$(jq -r '[.. | objects | select(has("payload")) | .payload][0] // empty' <<<"${out#"${out%%\{*}"}")"
    [ -n "$p" ] || die "unexpected inspect answer: $out"
    cast to-ascii "$p" ;;
  *) die "usage: $0 <deposit|request-withdrawal|execute|balance> ... (see --help)" ;;
esac
