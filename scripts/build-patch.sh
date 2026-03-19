#!/usr/bin/env bash
# build-patch.sh - Build pre-compiled binaries and generate a patch file
# for use with patch-package (or similar).
#
# Builds confluent-kafka-javascript.node for:
#   Node 22 (ABI 127) + Node 24 (ABI 137)  x  linux/arm64 + linux/amd64
#
# Requires: Docker with buildx and linux/arm64 + linux/amd64 emulation.
# Run from the repo root.
#
# arm64 is listed first — on Apple Silicon it runs natively (no QEMU).
#
# One worktree is created per arch. The first Node version on each arch does a
# full build (npm ci + node-gyp rebuild). Subsequent Node versions skip npm ci
# and run node-gyp configure + build without a clean step, so ninja reuses the
# already-compiled librdkafka object files and only recompiles the binding
# against the new Node headers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Node version -> ABI mapping
declare -A NODE_ABI=([22]=127 [24]=137)
PLATFORMS=(arm64 x64)
NODE_VERSIONS=(22 24)

DOCKER_IMAGE_BASE="node"

echo "==> Creating lib/binding directories"
for NODE_VER in "${NODE_VERSIONS[@]}"; do
  ABI="${NODE_ABI[$NODE_VER]}"
  for ARCH in "${PLATFORMS[@]}"; do
    mkdir -p "lib/binding/node-v${ABI}-linux-${ARCH}"
  done
done

# One worktree per arch, shared across Node versions.
declare -A ARCH_WORKTREES

setup_worktree() {
  local ARCH="$1"
  [[ -n "${ARCH_WORKTREES[$ARCH]:-}" ]] && return

  local WORKTREE_DIR
  WORKTREE_DIR="$(mktemp -d)"
  ARCH_WORKTREES[$ARCH]="$WORKTREE_DIR"

  git worktree add --detach "${WORKTREE_DIR}" HEAD

  echo "  -> Initializing submodules for ${ARCH}"
  git -C "${WORKTREE_DIR}" submodule update --init --recursive
}

cleanup_worktrees() {
  for ARCH in "${!ARCH_WORKTREES[@]}"; do
    git worktree remove --force "${ARCH_WORKTREES[$ARCH]}" 2>/dev/null || true
  done
}
trap cleanup_worktrees EXIT

build_binary() {
  local NODE_VER="$1"
  local ARCH="$2"
  local FIRST_FOR_ARCH="$3"  # "true" for the first Node version on this arch
  local ABI="${NODE_ABI[$NODE_VER]}"
  # x64 is the Node/binding convention; Docker uses amd64.
  local DOCKER_ARCH="linux/${ARCH/x64/amd64}"
  local OUT_DIR="${REPO_ROOT}/lib/binding/node-v${ABI}-linux-${ARCH}"
  local OUT_FILE="${OUT_DIR}/confluent-kafka-javascript.node"
  local WORKTREE_DIR="${ARCH_WORKTREES[$ARCH]}"

  echo ""
  echo "==> Building Node ${NODE_VER} (ABI ${ABI}) linux/${ARCH}"

  if [[ "$FIRST_FOR_ARCH" == "true" ]]; then
    echo "  -> Full build (npm ci + node-gyp rebuild)"
    docker run --rm \
      --platform "${DOCKER_ARCH}" \
      -v "${WORKTREE_DIR}:/v" \
      -w /v \
      "${DOCKER_IMAGE_BASE}:${NODE_VER}-bookworm-slim" \
      /bin/bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq build-essential python3 perl curl 2>/dev/null
        npm ci --ignore-scripts
        export CFLAGS=\"-fPIC\"
        npx node-gyp rebuild
      "
  else
    echo "  -> Incremental build (node-gyp configure + build, reusing compiled deps)"
    docker run --rm \
      --platform "${DOCKER_ARCH}" \
      -v "${WORKTREE_DIR}:/v" \
      -w /v \
      "${DOCKER_IMAGE_BASE}:${NODE_VER}-bookworm-slim" \
      /bin/bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq build-essential python3 perl curl 2>/dev/null
        export CFLAGS=\"-fPIC\"
        npx node-gyp configure
        npx node-gyp build
      "
  fi

  docker run --rm \
    --platform "${DOCKER_ARCH}" \
    -v "${WORKTREE_DIR}:/v" \
    -v "${OUT_DIR}:/out" \
    -w /v \
    "${DOCKER_IMAGE_BASE}:${NODE_VER}-bookworm-slim" \
    cp build/Release/confluent-kafka-javascript.node /out/confluent-kafka-javascript.node

  echo "    -> ${OUT_FILE}"
}

# Set up one worktree per arch upfront.
for ARCH in "${PLATFORMS[@]}"; do
  setup_worktree "$ARCH"
done

# Outer loop: arch. Inner loop: Node version.
# This keeps the shared worktree on the same arch between Node versions.
for ARCH in "${PLATFORMS[@]}"; do
  FIRST="true"
  for NODE_VER in "${NODE_VERSIONS[@]}"; do
    build_binary "$NODE_VER" "$ARCH" "$FIRST"
    FIRST="false"
  done
done

echo ""
echo "Done. Binaries:"
find lib/binding -name "*.node" | sort | sed 's/^/  /'
