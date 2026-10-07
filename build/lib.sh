# shellcheck shell=bash
# Shared helpers for foreclose-app/build.sh and fixtures/build.sh. Source it; do not run it.
#
# Everything that touches a machine runs inside BUILDER_IMAGE (cartesi-machine 0.21.0), built from the
# rollups-node tag's own Dockerfile. Overrides (all optional):
#   OUT            output dir                      (default: <repo>/out)
#   CACHE_DIR      clone + downloads + go cache     (default: <repo>/.cache)
#   NODE_SRC       existing checkout of NODE_COMMIT (default: CACHE_DIR/rollups-node, cloned on demand)
#   DOWNLOADS_DIR  dir holding the kernel/rootfs    (default: CACHE_DIR/downloads, fetched on demand)
#   BUILDER_IMAGE  builder image tag                (default from versions.env, built on demand)

set -euo pipefail

QA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
. "$QA_ROOT/versions.env"

OUT="${OUT:-$QA_ROOT/out}"
CACHE_DIR="${CACHE_DIR:-$QA_ROOT/.cache}"
NODE_SRC="${NODE_SRC:-$CACHE_DIR/rollups-node}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$CACHE_DIR/downloads}"

log() { printf '[qa-apps] %s\n' "$*" >&2; }
die() { printf '[qa-apps] ERROR: %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Clone the rollups-node tag (shallow) and refuse anything that is not NODE_COMMIT.
node_src() {
  if [ ! -d "$NODE_SRC/.git" ] && [ ! -f "$NODE_SRC/Makefile" ]; then
    log "cloning $NODE_REPO $NODE_TAG -> $NODE_SRC"
    mkdir -p "$(dirname "$NODE_SRC")"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$NODE_TAG" "$NODE_REPO" "$NODE_SRC"
  fi
  local head
  head="$(git -C "$NODE_SRC" rev-parse 'HEAD^{commit}')"
  [ "$head" = "$NODE_COMMIT" ] || die "$NODE_SRC is at $head, expected $NODE_COMMIT ($NODE_TAG)"
  [ -z "$(git -C "$NODE_SRC" status --porcelain --untracked-files=no)" ] || die "$NODE_SRC has local modifications"
}

# Kernel + rootfs, checked against versions.env AND the tag's test/dependencies.sha256.
machine_images() {
  node_src
  mkdir -p "$DOWNLOADS_DIR"
  local f url want pinned
  for spec in "$KERNEL_FILE|$KERNEL_URL|$KERNEL_SHA256" "$ROOTFS_FILE|$ROOTFS_URL|$ROOTFS_SHA256"; do
    IFS='|' read -r f url want <<<"$spec"
    pinned="$(awk -v f="test/downloads/$f" '$2 == f {print $1}' "$NODE_SRC/test/dependencies.sha256")"
    [ "$pinned" = "$want" ] || die "$f: versions.env sha256 $want != tag's test/dependencies.sha256 '$pinned'"
    grep -qx "$url" "$NODE_SRC/test/dependencies" || die "$f: URL $url is not in the tag's test/dependencies"
    if [ ! -f "$DOWNLOADS_DIR/$f" ]; then
      log "downloading $url"
      curl -fsSL --retry 3 -o "$DOWNLOADS_DIR/$f.part" "$url"
      mv "$DOWNLOADS_DIR/$f.part" "$DOWNLOADS_DIR/$f"
    fi
    [ "$(sha256_of "$DOWNLOADS_DIR/$f")" = "$want" ] || die "$DOWNLOADS_DIR/$f: sha256 mismatch (want $want)"
  done
  # cartesi-machine looks for linux.bin / rootfs.ext2 in /usr/share/cartesi-machine/images
  ln -sfn "$KERNEL_FILE" "$DOWNLOADS_DIR/linux.bin"
  ln -sfn "$ROOTFS_FILE" "$DOWNLOADS_DIR/rootfs.ext2"
}

# Builder image = rollups-node Dockerfile, stage go-prepare (emulator .deb + Go, both sha256-pinned upstream).
builder_image() {
  node_src
  local have
  have="$(docker image inspect --format '{{index .Config.Labels "qa-apps.node-commit"}}' "$BUILDER_IMAGE" 2>/dev/null || true)"
  if [ "$have" != "$NODE_COMMIT" ]; then
    log "building $BUILDER_IMAGE (rollups-node Dockerfile --target $BUILDER_TARGET at ${NODE_COMMIT:0:8})"
    docker build --quiet --target "$BUILDER_TARGET" --build-arg "EMULATOR_VERSION=$EMULATOR_VERSION" \
      --label "qa-apps.node-commit=$NODE_COMMIT" -t "$BUILDER_IMAGE" "$NODE_SRC" >/dev/null
  fi
  local v
  v="$(docker run --rm --entrypoint cartesi-machine "$BUILDER_IMAGE" --version | head -1)"
  [ "$v" = "cartesi-machine $EMULATOR_VERSION" ] || die "builder has '$v', expected cartesi-machine $EMULATOR_VERSION"
}

# Run a shell script inside the builder. Mounts: /repo (ro), /node (ro), images (ro), /out (rw).
in_builder() {
  mkdir -p "$OUT"
  docker run --rm --user root \
    -v "$QA_ROOT":/repo:ro -v "$NODE_SRC":/node:ro -v "$OUT":/out \
    -v "$(cd "$DOWNLOADS_DIR" && pwd)":/usr/share/cartesi-machine/images:ro \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    --entrypoint bash "$BUILDER_IMAGE" -euo pipefail -c "$1"
}

# Template hash as the node/CLI read it: 32 bytes at offset 0x60 of hash_tree.sht.
template_hash() {
  printf '0x%s\n' "$(od -An -tx1 -j96 -N32 "$1/hash_tree.sht" | tr -d ' \n')"
}

# Cross-check: cartesi-machine-stored-hash must agree with hash_tree.sht@0x60, and the snapshot must load.
check_snapshot() {
  local dir="$1" rel h1 h2
  rel="${dir#"$OUT"/}"
  h1="$(template_hash "$dir")"
  h2="$(in_builder "cartesi-machine-stored-hash /out/$rel | tr -d '[:space:]'; cartesi-machine --load=/out/$rel -- true >/dev/null 2>&1 || echo LOAD-FAILED")"
  [ "$h1" = "$h2" ] || die "$dir: hash_tree.sht@0x60=$h1 but cartesi-machine-stored-hash/load says '$h2'"
  echo "$h1"
}
