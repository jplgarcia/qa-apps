#!/usr/bin/env bash
# Build every snapshot a second time under another name and require the same template hash.
# Needs a first build in $OUT (make all). The rebuilt copies are deleted afterwards.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
NETWORKS="${NETWORKS:-devnet sepolia base-sepolia op-sepolia}"
FIXTURES="echo mcycle-overflow unexpected-yield invalid-outputs-root invalid-outputs-root-length invalid-template-outputs-root"
SFX=.rebuild
for n in $NETWORKS; do "$QA_ROOT/foreclose-app/build.sh" "$n" "foreclose-app-$n$SFX" >/dev/null; done
"$QA_ROOT/fixtures/build.sh" "$SFX" >/dev/null
fail=0
for name in $(for n in $NETWORKS; do echo "foreclose-app-$n"; done) $FIXTURES; do
  a="$(cat "$OUT/$name.hash" 2>/dev/null || echo missing)"; b="$(cat "$OUT/$name$SFX.hash")"
  if [ "$a" = "$b" ]; then echo "reproducible $name $a"; else echo "MISMATCH $name first=$a second=$b"; fail=1; fi
  rm -rf "${OUT:?}/$name$SFX" "$OUT/$name$SFX.hash" "$OUT/$name$SFX.build.log"
done
exit "$fail"
