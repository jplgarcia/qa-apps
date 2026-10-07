#!/usr/bin/env bash
# Build the rollups-node synthetic terminal-state fixtures from the pinned node tag.
#
#   fixtures/build.sh [suffix]
#
# Output: $OUT/<fixture><suffix>/ snapshots and $OUT/<fixture><suffix>.hash for
#   echo (input of mcycle-overflow), mcycle-overflow, unexpected-yield, invalid-outputs-root,
#   invalid-outputs-root-length, invalid-template-outputs-root.
# Commands = rollups-node v2.0.0-alpha.13 Makefile targets applications/echo-dapp, mcycle-overflow-dapp,
# unexpected-yield-dapp, invalid-outputs-root-dapp, invalid-outputs-root-length-dapp,
# invalid-template-outputs-root-dapp. The generator (test/tooling/terminalmachine) is built from the clone.
set -euo pipefail
. "$(dirname "$0")/../build/lib.sh"

SFX="${1:-}"
FIXTURES="echo mcycle-overflow unexpected-yield invalid-outputs-root invalid-outputs-root-length invalid-template-outputs-root"

node_src
machine_images
builder_image

for f in $FIXTURES; do rm -rf "${OUT:?}/$f$SFX" "$OUT/$f$SFX.hash"; done
log "building fixtures (suffix '$SFX') from rollups-node ${NODE_COMMIT:0:8}"
in_builder "
S='$SFX'
cartesi-machine --ram-length=128Mi --store=/out/echo\$S --final-hash -- \
  ioctl-echo-loop --vouchers=1 --delegate-call-vouchers=1 --notices=1 --reports=1 --verbose=1 > /out/echo\$S.build.log 2>&1 \
  || { tail -20 /out/echo\$S.build.log; exit 1; }
# go run \$(GO_BUILD_PARAMS) ./test/tooling/terminalmachine, as in the node Makefile (module cache from the image)
cp -r /node /tmp/node && cd /tmp/node
export GOFLAGS=-mod=mod GOTOOLCHAIN=local GOCACHE=/tmp/gocache
go build -ldflags '-s -w -r /usr/lib' -o /tmp/terminalmachine ./test/tooling/terminalmachine
T=/tmp/terminalmachine
\$T mcycle-overflow --source=/out/echo\$S --output=/out/mcycle-overflow\$S
\$T unexpected-yield --output=/out/unexpected-yield\$S
\$T invalid-outputs-root --kind=value --output=/out/invalid-outputs-root\$S
\$T invalid-outputs-root --kind=length --output=/out/invalid-outputs-root-length\$S
\$T invalid-outputs-root --kind=template --output=/out/invalid-template-outputs-root\$S
chown -R \$HOST_UID:\$HOST_GID /out/echo\$S /out/echo\$S.build.log /out/mcycle-overflow\$S /out/unexpected-yield\$S \
  /out/invalid-outputs-root\$S /out/invalid-outputs-root-length\$S /out/invalid-template-outputs-root\$S
"
for f in $FIXTURES; do
  H="$(check_snapshot "$OUT/$f$SFX")"
  echo "$H" > "$OUT/$f$SFX.hash"
  echo "$f$SFX $H"
done
