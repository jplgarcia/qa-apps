#!/usr/bin/env bash
# Compare the built template hashes in $OUT with the recorded ones in hashes.txt.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
fail=0
while read -r name want; do
  case "$name" in ''|'#'*) continue ;; esac
  got="$(cat "$OUT/$name.hash" 2>/dev/null || echo missing)"
  if [ "$got" = "$want" ]; then echo "ok $name $got"; else echo "MISMATCH $name built=$got recorded=$want"; fail=1; fi
done < "$QA_ROOT/hashes.txt"
exit "$fail"
