#!/usr/bin/env bash
# Build the foreclose-app machine snapshot for one network.
#
#   foreclose-app/build.sh <devnet|sepolia|base-sepolia> [output-name]
#
# Output: $OUT/<output-name>/ (default foreclose-app-<network>), a `cartesi-machine --store` dir accepted by
# `cartesi-rollups-cli deploy application`, plus $OUT/<output-name>.hash (template hash). The only per-network
# difference is TRUSTED_ERC20_TOKEN (and, in principle, TRUSTED_ERC20_PORTAL), baked in via --env, so the
# template hash differs per network and a snapshot only accepts deposits of its own network's token.
#
# Machine command = rollups-node v2.0.0-alpha.13 Makefile target applications/erc20-withdrawal-dapp.
set -euo pipefail
. "$(dirname "$0")/../build/lib.sh"

NETWORK="${1:-}"
[ -n "$NETWORK" ] || die "usage: $0 <devnet|sepolia|base-sepolia> [output-name]"
NET_FILE="$QA_ROOT/networks/$NETWORK.env"
[ -f "$NET_FILE" ] || die "unknown network '$NETWORK' (no $NET_FILE)"
# shellcheck disable=SC1090
. "$NET_FILE"
NAME="${2:-foreclose-app-$NETWORK}"

# The dapp script is appended to the machine's init: any byte change changes the template hash.
SRC="$QA_ROOT/foreclose-app/install.sh"
[ "$(sha256_of "$SRC")" = "$INSTALL_SH_SHA256" ] || die "$SRC differs from the pinned rollups-node copy"
node_src
cmp -s "$SRC" "$NODE_SRC/test/dapps/erc20-withdrawal/install.sh" \
  || die "$SRC is not byte-identical to test/dapps/erc20-withdrawal/install.sh at $NODE_COMMIT"
machine_images
builder_image

log "building $NAME: token $TOKEN_SYMBOL $TOKEN, portal $ERC20_PORTAL"
rm -rf "${OUT:?}/$NAME" "$OUT/$NAME.hash"
in_builder "
cartesi-machine --ram-length=128Mi \
  --flash-drive=label:accounts,length:4Mi,mke2fs:false,mount:false,user:dapp \
  --env=TRUSTED_ERC20_PORTAL=$ERC20_PORTAL \
  --env=TRUSTED_ERC20_TOKEN=$TOKEN \
  --append-init-file=/repo/foreclose-app/install.sh \
  --store=/out/$NAME --final-hash -- /usr/local/bin/erc20-withdrawal-dapp > /out/$NAME.build.log 2>&1 \
  || { tail -20 /out/$NAME.build.log; exit 1; }
chown -R \$HOST_UID:\$HOST_GID /out/$NAME /out/$NAME.build.log
"
H="$(check_snapshot "$OUT/$NAME")"
echo "$H" > "$OUT/$NAME.hash"
log "$NAME template hash $H"
echo "$NAME $H"
