#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$ROOT_DIR/host-profiles/firecracker-host.profile"
BIN="${FIRECRACKER_BIN:-$(command -v firecracker || printf '%s' firecracker)}"
KERNEL_IMAGE="${KERNEL_IMAGE:-}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-}"
SOCKET="${FIRECRACKER_SOCKET:-$ROOT_DIR/results/firecracker.socket}"

if [[ -z "$KERNEL_IMAGE" || -z "$ROOTFS_IMAGE" ]]; then
  printf 'Set KERNEL_IMAGE and ROOTFS_IMAGE before launching Firecracker.\n' >&2
  exit 2
fi

rm -f "$SOCKET"
exec firejail \
  --quiet \
  --profile="$PROFILE" \
  --whitelist="$ROOT_DIR" \
  -- "$BIN" --api-sock "$SOCKET" "$@"
