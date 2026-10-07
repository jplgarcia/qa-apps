#!/usr/bin/env bash
# Emergency path of a foreclose-app deployment (rollups-contracts v3.0.0-alpha.10, node v2.0.0-alpha.13 tools).
#
#   scripts/emergency.sh status    TARGET [--account ADDR]
#   scripts/emergency.sh foreclose TARGET                         signer = the guardian
#   scripts/emergency.sh withdraw  TARGET --account ADDR [--epoch E] [--work DIR] [--host-work DIR] [--replay]
#   scripts/emergency.sh refund    TARGET --input-index N [--work DIR] [--host-work DIR]
#
# TARGET is either --deployment FILE (record written by scripts/deploy.sh) or
#   --network NET --app 0xADDR [--template PATH]   (PATH = the app's template as the machine tool sees it)
#
# withdraw = the documented sequence for one account:
#   1. machine-tool replay   --template T --application APP --to-epoch E --store WORK/snap-E
#        (E = last CLAIM_ACCEPTED epoch from the node DB unless --epoch; the snapshot is reused unless --replay)
#   2. machine-tool prove accounts-drive --snapshot WORK/snap-E with the layout READ FROM THE APP ON CHAIN
#        (getWithdrawalConfig), never typed by hand -> drive-root proof + withdraw proof
#   3. cli prove-drive-root APP   (only if the app has no proved root yet; refuses if a different root is proved)
#   4. cli withdraw APP           and checks the account was paid exactly its drive balance, and the app debited
# refund = cli refund APP N with the InputAdded bytes read from the InputBox log (not from the node), and, for a
#   deposit of the app's token through the Erc20Portal, checks the depositor got exactly the amount back.
#
# --work      directory as seen by CARTESI_MACHINE_TOOL / CARTESI_CLI (default ./emergency-work)
# --host-work the same directory as seen from this host (default: --work); proofs are read from here
# Env: RPC_URL, CARTESI_AUTH_PRIVATE_KEY (guardian for foreclose; any funded account otherwise: withdraw and
#      refund are permissionless and always pay the account owner / depositor), CARTESI_CLI, CARTESI_MACHINE_TOOL.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

CMD="${1:-}"; [ $# -gt 0 ] && shift
DEPLOYMENT='' NETWORK='' APP='' TEMPLATE='' ACCOUNT='' EPOCH='' INPUT_INDEX='' WORK="$PWD/emergency-work" HOST_WORK='' REPLAY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --deployment) DEPLOYMENT="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --epoch) EPOCH="$2"; shift 2 ;;
    --input-index) INPUT_INDEX="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --host-work) HOST_WORK="$2"; shift 2 ;;
    --replay) REPLAY=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done
case "$CMD" in status|foreclose|withdraw|refund) ;; *) die "usage: $0 <status|foreclose|withdraw|refund> ... (see --help)" ;; esac
if [ -n "$DEPLOYMENT" ]; then
  [ -f "$DEPLOYMENT" ] || die "no deployment record $DEPLOYMENT"
  NETWORK="${NETWORK:-$(record_get "$DEPLOYMENT" network)}"
  APP="${APP:-$(record_get "$DEPLOYMENT" application)}"
  TEMPLATE="${TEMPLATE:-$(record_get "$DEPLOYMENT" template_path)}"
fi
[ -n "$NETWORK" ] && is_addr "${APP:-}" || die "give --deployment FILE or --network NET --app 0xADDR"
HOST_WORK="${HOST_WORK:-$WORK}"
load_network "$NETWORK"
has_code "$APP" || die "$APP has no code on $NETWORK"

foreclosed() { [ "$(call "$APP" 'isForeclosed()(bool)')" = true ]; }
drive_root() { call "$APP" 'getAccountsDriveMerkleRoot()(bool,bytes32)' | tr '\n' ' '; }   # "true 0x.."
cli() {
  # shellcheck disable=SC2086
  $CARTESI_CLI "$@"
}
tool() {
  # shellcheck disable=SC2086
  $CARTESI_MACHINE_TOOL "$@"
}

status() {
  local wc
  wc="$(call "$APP" 'getWithdrawalConfig()((address,uint8,uint8,uint64,address))')"
  echo "application        $APP ($NETWORK)"
  echo "foreclosed         $(call "$APP" 'isForeclosed()(bool)')"
  echo "withdrawal config  $wc   (guardian, log2LeavesPerAccount, log2MaxNumOfAccounts, accountsDriveStartIndex, builder)"
  echo "drive root proved  $(drive_root)"
  echo "withdrawals        $(call "$APP" 'getNumberOfWithdrawals()(uint256)' | first)"
  echo "refunds issued     $(call "$APP" 'getNumberOfIssuedRefunds()(uint256)' | first)"
  echo "app $TOKEN_SYMBOL balance $(token_balance "$APP")"
  [ -z "$ACCOUNT" ] || echo "$ACCOUNT $TOKEN_SYMBOL balance $(token_balance "$ACCOUNT")"
}

do_foreclose() {
  need_key "guardian"
  local me guardian
  me="$(signer)"; guardian="$(call "$APP" 'getGuardian()(address)')"
  same_addr "$me" "$guardian" || die "signer $me is not the guardian $guardian"
  foreclosed && { log "already foreclosed"; return 0; }
  cli foreclose "$APP" --yes --json
  foreclosed || die "isForeclosed() is still false"
  log "foreclosed $APP"
}

# account word (32 bytes hex) -> "owner balance": LibUsdAccount = uint96 little-endian balance | address
decode_account() {
  local w="${1#0x}" le="" i
  for ((i = 22; i >= 0; i -= 2)); do le="$le${w:$i:2}"; done
  printf '0x%s %s\n' "${w:24:40}" "$(cast to-dec "0x$le")"
}

do_withdraw() {
  need_key "gas payer"
  is_addr "$ACCOUNT" || die "--account 0xADDR is required"
  [ -n "$TEMPLATE" ] || die "--template PATH is required (or a --deployment record with template_path)"
  foreclosed || die "application is not foreclosed: the guardian must run 'foreclose' first"
  local l m idx
  read -r _ l m idx _ <<<"$(call "$APP" 'getWithdrawalConfig()((address,uint8,uint8,uint64,address))' | tr -d '()' | tr ',' ' ')"
  if [ -z "$EPOCH" ]; then
    EPOCH="$(cli read epochs "$APP" --status CLAIM_ACCEPTED --limit 1 --descending | jq -r '.data[0].index // empty')"
    [ -n "$EPOCH" ] || die "no CLAIM_ACCEPTED epoch for $APP in the node database (pass --epoch)"
    EPOCH="$(cast to-dec "$EPOCH")"
  fi
  local tag snap drp wdp
  tag="$(lc "${APP:2:8}")-e$EPOCH"
  snap="$WORK/snap-$tag"; drp="$WORK/drive-root-proof-$tag.json"; wdp="$WORK/withdraw-proof-$tag-$(lc "${ACCOUNT:2:8}").json"
  mkdir -p "$HOST_WORK"
  log "layout from chain: accounts_drive_start_index=$idx log2_max_num_of_accounts=$m log2_leaves_per_account=$l; epoch $EPOCH"
  if [ "$REPLAY" = 1 ] || [ ! -f "$HOST_WORK/snap-$tag/hash_tree.sht" ]; then
    rm -rf "${HOST_WORK:?}/snap-$tag"
    log "1/4 machine-tool replay --to-epoch $EPOCH"
    tool replay --template "$TEMPLATE" --application "$APP" --to-epoch "$EPOCH" --store "$snap"
  else
    log "1/4 reusing $snap"
  fi
  rm -f "$HOST_WORK/$(basename "$drp")" "$HOST_WORK/$(basename "$wdp")"
  log "2/4 machine-tool prove accounts-drive --account $ACCOUNT"
  tool prove accounts-drive --snapshot "$snap" --accounts-drive-start-index "$idx" \
    --log2-max-num-of-accounts "$m" --log2-leaves-per-account "$l" --account "$ACCOUNT" \
    --out-drive-root-proof "$drp" --out-withdraw-proof "$wdp"
  local root word aidx owner bal proved onchain_root
  root="$(jq -r .accounts_drive_merkle_root "$HOST_WORK/$(basename "$drp")")"
  word="$(jq -r .account "$HOST_WORK/$(basename "$wdp")")"
  aidx="$(cast to-dec "$(jq -r .account_index "$HOST_WORK/$(basename "$wdp")")")"
  read -r owner bal <<<"$(decode_account "$word")"
  same_addr "$owner" "$ACCOUNT" || die "proof account word belongs to $owner, not $ACCOUNT"
  log "drive root $root; account index $aidx; drive balance $bal"
  [ "$(call "$APP" 'wereAccountFundsWithdrawn(uint256)(bool)' "$aidx")" = false ] \
    || die "account index $aidx was already withdrawn (the contract would revert AccountFundsAlreadyWithdrawn)"

  read -r proved onchain_root <<<"$(drive_root)"
  if [ "$proved" = true ]; then
    [ "$onchain_root" = "$root" ] || die "the app already has drive root $onchain_root proved, but epoch $EPOCH gives $root (use the epoch that was proved)"
    log "3/4 drive root already proved"
  else
    log "3/4 cli prove-drive-root"
    cli prove-drive-root "$APP" --proof-file "$drp" --yes --json
    read -r proved onchain_root <<<"$(drive_root)"
    [ "$proved" = true ] && [ "$onchain_root" = "$root" ] || die "drive root not recorded after prove-drive-root"
  fi

  local u0 a0 u1 a1
  u0="$(token_balance "$ACCOUNT")"; a0="$(token_balance "$APP")"
  log "4/4 cli withdraw (account $u0, app $a0 $TOKEN_SYMBOL base units)"
  cli withdraw "$APP" --proof-file "$wdp" --yes --json
  u1="$(token_balance "$ACCOUNT")"; a1="$(token_balance "$APP")"
  [ "$(call "$APP" 'wereAccountFundsWithdrawn(uint256)(bool)' "$aidx")" = true ] || die "wereAccountFundsWithdrawn($aidx) is false"
  [ "$((u1 - u0))" = "$bal" ] && [ "$((a0 - a1))" = "$bal" ] \
    || die "paid amount mismatch: account $u0 -> $u1, app $a0 -> $a1, drive balance $bal"
  log "withdrawn: $ACCOUNT +$bal ($u0 -> $u1), app -$bal ($a0 -> $a1)"
}

do_refund() {
  need_key "gas payer"
  [[ "${INPUT_INDEX:-}" =~ ^[0-9]+$ ]] || die "--input-index N is required"
  foreclosed || die "application is not foreclosed: the guardian must run 'foreclose' first"
  [ "$(call "$APP" 'wasRefundForInputIssued(uint256)(bool)' "$INPUT_INDEX")" = false ] || die "refund for input $INPUT_INDEX was already issued"
  local from logs data input file sender payload depositor amount b0 b1
  from="$(call "$APP" 'getDeploymentBlockNumber()(uint256)' | first)"
  logs="$(cast logs --rpc-url "$RPC_URL" --json --from-block "$from" --address "$INPUT_BOX" \
    'InputAdded(address indexed appContract, uint256 indexed index, bytes input)' "$APP" "$INPUT_INDEX")"
  data="$(jq -r '.[0].data // empty' <<<"$logs")"
  [ -n "$data" ] || die "no InputAdded log for input $INPUT_INDEX of $APP since block $from"
  input="$(cast abi-decode 'f()(bytes)' "$data")"
  file="refund-input-$(lc "${APP:2:8}")-$INPUT_INDEX.hex"
  mkdir -p "$HOST_WORK"; printf '%s\n' "$input" > "$HOST_WORK/$file"
  sender="$(cast calldata-decode 'EvmAdvance(uint256,address,address,uint256,uint256,uint256,uint256,bytes)' "$input" | sed -n 3p)"
  payload="$(cast calldata-decode 'EvmAdvance(uint256,address,address,uint256,uint256,uint256,uint256,bytes)' "$input" | sed -n 8p)"
  depositor=
  if same_addr "$sender" "$ERC20_PORTAL" && same_addr "0x${payload:2:40}" "$TOKEN"; then
    depositor="0x${payload:42:40}"; amount="$(cast to-dec "0x${payload:82:64}")"
    b0="$(token_balance "$depositor")"
    log "input $INPUT_INDEX = $TOKEN_SYMBOL deposit of $amount by $depositor (balance $b0)"
  else
    log "input $INPUT_INDEX was sent by $sender (not a $TOKEN_SYMBOL Erc20Portal deposit): refunding without a balance check"
  fi
  cli refund "$APP" "$INPUT_INDEX" --input-file "$WORK/$file" --yes --json
  [ "$(call "$APP" 'wasRefundForInputIssued(uint256)(bool)' "$INPUT_INDEX")" = true ] || die "wasRefundForInputIssued($INPUT_INDEX) is false"
  if [ -n "$depositor" ]; then
    b1="$(token_balance "$depositor")"
    [ "$((b1 - b0))" = "$amount" ] || die "depositor balance $b0 -> $b1, expected +$amount"
    log "refunded: $depositor +$amount ($b0 -> $b1)"
  fi
}

case "$CMD" in
  status) status ;;
  foreclose) do_foreclose ;;
  withdraw) do_withdraw ;;
  refund) do_refund ;;
esac
