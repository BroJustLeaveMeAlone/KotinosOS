#!/usr/bin/env bash
#
# Builds the OS container image and converts it to a bootable disk image.
#
# Run from the repo root as root (podman must be rootful; the image builder
# needs a privileged container and access to the host container store).
#
#   ./build.sh [BUILD_ID] [TYPE]
#
# BUILD_ID defaults to a UTC timestamp and is baked into
# /usr/lib/kotinos-release so a booted system can identify itself.
# TYPE defaults to vhd for Hyper-V.

set -euo pipefail

BUILD_ID="${1:-$(date -u +%Y%m%d.%H%M%S)}"
TYPE="${2:-vhd}"

IMAGE="localhost/kotinos:${BUILD_ID}"
BUILDER="quay.io/centos-bootc/bootc-image-builder:latest"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Override when the repo lives on a Windows drvfs mount (/mnt/c/...): osbuild
# needs xattrs and SELinux labels that drvfs cannot provide, so the disk image
# must be written to a Linux-native filesystem and copied out afterwards.
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/output}"

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (podman needs to be rootful here)" >&2
    exit 1
fi

# Development SSH key, if the credentials overlay is present. Release builds
# have no config.dev.toml and so bake in no key.
DEV_SSH_KEY=""
if [[ -f "${REPO_ROOT}/config.dev.toml" ]]; then
    DEV_SSH_KEY="$(grep -o 'ssh-[a-z0-9-]* [A-Za-z0-9+/=]* *[^"]*' "${REPO_ROOT}/config.dev.toml" | head -1)"
fi

echo "==> Building ${IMAGE}"
podman build \
    --build-arg "BUILD_ID=${BUILD_ID}" \
    --build-arg "DEV_SSH_KEY=${DEV_SSH_KEY}" \
    --tag "${IMAGE}" \
    --file "${REPO_ROOT}/Containerfile" \
    "${REPO_ROOT}"

# Tag as :latest too, so bootc upgrade has a stable ref to follow.
podman tag "${IMAGE}" localhost/kotinos:latest

echo "==> Building ${TYPE} disk image"
mkdir -p "${OUTPUT_DIR}"

# Merge the committed disk layout with the gitignored credentials overlay,
# if present. TOML arrays-of-tables concatenate cleanly, so no key conflicts.
# Release builds must run without config.dev.toml present.
BUILD_CONFIG="$(mktemp /tmp/kotinos-config.XXXXXX.toml)"
trap 'rm -f "${BUILD_CONFIG}"' EXIT
cat "${REPO_ROOT}/config.toml" > "${BUILD_CONFIG}"
if [[ -f "${REPO_ROOT}/config.dev.toml" ]]; then
    echo "    including config.dev.toml (test credentials -- not for release)"
    printf '\n' >> "${BUILD_CONFIG}"
    cat "${REPO_ROOT}/config.dev.toml" >> "${BUILD_CONFIG}"
fi

podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v "${BUILD_CONFIG}:/config.toml:ro" \
    -v "${OUTPUT_DIR}:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BUILDER}" \
    --type "${TYPE}" \
    --rootfs btrfs \
    --progress term \
    "${IMAGE}"

echo "==> Done. Build ID: ${BUILD_ID}"
find "${OUTPUT_DIR}" -type f \( -name '*.vhd' -o -name '*.qcow2' -o -name '*.raw' \) -printf '%p (%s bytes)\n'
