#!/usr/bin/env bash
# build-patch.sh - Build pre-compiled binaries and generate a patch file
# for use with patch-package (or similar).
#
# Builds confluent-kafka-javascript.node for:
#   Node 20 (ABI 115) + Node 22 (ABI 127)  x  linux/arm64 + linux/amd64
#
# Requires: Docker with buildx and linux/arm64 + linux/amd64 emulation.
# Run from the repo root.
#
# arm64 is listed first — on Apple Silicon it runs natively (no QEMU).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Node version -> ABI mapping
declare -A NODE_ABI=([20]=115 [22]=127)
PLATFORMS=(arm64 amd64)
NODE_VERSIONS=(20 22)

DOCKER_IMAGE_BASE="node"

echo "==> Creating lib/binding directories"
for NODE_VER in "${NODE_VERSIONS[@]}"; do
  ABI="${NODE_ABI[$NODE_VER]}"
  for ARCH in "${PLATFORMS[@]}"; do
    mkdir -p "lib/binding/node-v${ABI}-linux-${ARCH}"
  done
done

build_binary() {
  local NODE_VER="$1"
  local ARCH="$2"
  local ABI="${NODE_ABI[$NODE_VER]}"
  local DOCKER_ARCH="linux/${ARCH}"
  local OUT_DIR="${REPO_ROOT}/lib/binding/node-v${ABI}-linux-${ARCH}"
  local OUT_FILE="${OUT_DIR}/confluent-kafka-javascript.node"

  echo ""
  echo "==> Building Node ${NODE_VER} (ABI ${ABI}) linux/${ARCH}"

  # Fresh throw-away worktree for this build — no cross-build pollution.
  local WORKTREE_DIR
  WORKTREE_DIR="$(mktemp -d)"
  git worktree add --detach "${WORKTREE_DIR}" HEAD
  # shellcheck disable=SC2064
  trap "git worktree remove --force '${WORKTREE_DIR}' 2>/dev/null || true" RETURN

  echo "  -> Initializing submodules"
  git -C "${WORKTREE_DIR}" submodule update --init --recursive

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
      export CFLAGS="-fPIC"
      npx node-gyp rebuild
    "

  docker run --rm \
    --platform "${DOCKER_ARCH}" \
    -v "${WORKTREE_DIR}:/v" \
    -v "${OUT_DIR}:/out" \
    -w /v \
    "${DOCKER_IMAGE_BASE}:${NODE_VER}-bookworm-slim" \
    cp build/Release/confluent-kafka-javascript.node /out/confluent-kafka-javascript.node

  echo "    -> ${OUT_FILE}"
}

for NODE_VER in "${NODE_VERSIONS[@]}"; do
  for ARCH in "${PLATFORMS[@]}"; do
    build_binary "$NODE_VER" "$ARCH"
  done
done

echo ""
echo "Done. Binaries:"
find lib/binding -name "*.node" | sort | sed 's/^/  /'
