#!/usr/bin/env bash
# Package every snapshot listed in hashes.txt in $OUT as <name>.tar.gz (deterministic tar), plus SHA256SUMS and template-hashes.txt.
# Usage of a release asset: tar -xzf <name>.tar.gz  ->  <name>/ (pass that dir to `deploy application`).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
DIST="${DIST:-$QA_ROOT/dist}"
rm -rf "$DIST"; mkdir -p "$DIST"
: > "$DIST/template-hashes.txt"
while read -r name _; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -f "$OUT/$name/hash_tree.sht" ] || die "$OUT/$name is not built"
  # GNU tar + gzip from the builder image, so the archive bytes do not depend on the host's tar
  in_builder "tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -C /out -cf - $name | gzip -n -9" \
    > "$DIST/$name.tar.gz"
  echo "$name $(cat "$OUT/$name.hash")" >> "$DIST/template-hashes.txt"
done < "$QA_ROOT/hashes.txt"
(cd "$DIST" && for f in *.tar.gz template-hashes.txt; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done > SHA256SUMS)
cat "$DIST/template-hashes.txt"
