#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$ROOT_DIR/host-profiles/crosvm-host.profile"
BIN="${CROSVM_BIN:-$(command -v crosvm || printf '%s' crosvm)}"
KERNEL_IMAGE="${KERNEL_IMAGE:-}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-}"
BOOT_ARGS="${BOOT_ARGS:-console=ttyS0 reboot=k panic=1}"

if [[ -z "$KERNEL_IMAGE" || -z "$ROOTFS_IMAGE" ]]; then
  printf 'Set KERNEL_IMAGE and ROOTFS_IMAGE before launching crosvm.\n' >&2
  exit 2
fi

exec firejail \
  --quiet \
  --profile="$PROFILE" \
  --whitelist="$ROOT_DIR" \
  -- "$BIN" run \
  --params "$BOOT_ARGS" \
  --rwdisk "$ROOTFS_IMAGE" \
  "$KERNEL_IMAGE" \
  "$@"
