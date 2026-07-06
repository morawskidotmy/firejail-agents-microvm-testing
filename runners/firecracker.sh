#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$ROOT_DIR/host-profiles/firecracker-host.profile"
BIN="${FIRECRACKER_BIN:-$(command -v firecracker || printf '%s' firecracker)}"
KERNEL_IMAGE="${KERNEL_IMAGE:-}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-}"
BOOT_ARGS="${BOOT_ARGS:-console=ttyS0 reboot=k panic=1 pci=off}"
SOCKET="${FIRECRACKER_SOCKET:-$ROOT_DIR/results/firecracker.socket}"
CONFIG="${FIRECRACKER_CONFIG:-$ROOT_DIR/results/firecracker-config.json}"
VCPUS="${FIRECRACKER_VCPUS:-1}"
MEM_MIB="${FIRECRACKER_MEM_MIB:-128}"

if [[ -z "$KERNEL_IMAGE" || -z "$ROOTFS_IMAGE" ]]; then
  printf 'Set KERNEL_IMAGE and ROOTFS_IMAGE before launching Firecracker.\n' >&2
  exit 2
fi

rm -f "$SOCKET"
mkdir -p "$(dirname "$CONFIG")"

cat > "$CONFIG" <<EOF
{
  "boot-source": {
    "kernel_image_path": "$KERNEL_IMAGE",
    "boot_args": "$BOOT_ARGS"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "$ROOTFS_IMAGE",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": $VCPUS,
    "mem_size_mib": $MEM_MIB
  }
}
EOF

exec firejail \
  --quiet \
  --profile="$PROFILE" \
  --whitelist="$ROOT_DIR" \
  --whitelist="$KERNEL_IMAGE" \
  --whitelist="$ROOTFS_IMAGE" \
  -- "$BIN" --config-file "$CONFIG" --api-sock "$SOCKET" "$@"
