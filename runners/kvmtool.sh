#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$ROOT_DIR/host-profiles/kvmtool-host.profile"
BIN="${KVMTOOL_BIN:-$(command -v lkvm || command -v kvmtool || printf '%s' lkvm)}"
KERNEL_IMAGE="${KERNEL_IMAGE:-}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-}"
BOOT_ARGS="${BOOT_ARGS:-console=ttyS0 reboot=k panic=1}"

if [[ -z "$KERNEL_IMAGE" || -z "$ROOTFS_IMAGE" ]]; then
  printf 'Set KERNEL_IMAGE and ROOTFS_IMAGE before launching kvmtool.\n' >&2
  exit 2
fi

exec firejail \
  --quiet \
  --profile="$PROFILE" \
  --whitelist="$ROOT_DIR" \
  -- "$BIN" run \
  --kernel "$KERNEL_IMAGE" \
  --disk "$ROOTFS_IMAGE" \
  --console virtio \
  --params "$BOOT_ARGS" \
  "$@"
