#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="$ROOT_DIR/images"
BUILD_DIR="$ROOT_DIR/.build"
KERNEL_VERSION="6.1.110"
ROOTFS_SIZE_MB=64

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARNING: %s\n' "$*" >&2
}

mkdir -p "$IMAGES_DIR" "$BUILD_DIR"

install_build_deps() {
  log "Installing kernel build dependencies"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y \
      build-essential \
      libncurses-dev \
      bison \
      flex \
      libssl-dev \
      libelf-dev \
      bc \
      xz-utils \
      cpio \
      e2fsprogs
  else
    warn "apt-get not found. Please install build dependencies manually:"
    warn "  - build-essential (gcc, make, etc.)"
    warn "  - libncurses-dev, libssl-dev, libelf-dev"
    warn "  - bison, flex, bc"
    warn "  - xz-utils, cpio, e2fsprogs"
  fi
}

download_kernel() {
  local kernel_tarball="$BUILD_DIR/linux-$KERNEL_VERSION.tar.xz"
  
  if [[ -f "$kernel_tarball" ]]; then
    log "Kernel source already downloaded"
    return 0
  fi
  
  log "Downloading Linux kernel $KERNEL_VERSION"
  wget -q --show-progress -O "$kernel_tarball" \
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
  
  log "Extracting kernel source"
  tar -xf "$kernel_tarball" -C "$BUILD_DIR"
}

configure_kernel() {
  local kernel_dir="$BUILD_DIR/linux-$KERNEL_VERSION"
  
  log "Configuring minimal kernel for VM boot"
  
  cd "$kernel_dir"
  
  # Start with minimal config
  make defconfig
  
  # Enable necessary options for VM boot
  cat >> .config <<'EOF'
# Serial console (required for all VMMs)
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_8250_NR_UARTS=1
CONFIG_SERIAL_8250_RUNTIME_UARTS=1

# PCI support (required for kvmtool/crosvm virtio devices)
CONFIG_PCI=y

# Virtio devices (required for block/network)
CONFIG_VIRTIO=y
CONFIG_VIRTIO_RING=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y

# Filesystem support
CONFIG_EXT4_FS=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# Initramfs support
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y

# Disable unnecessary features to speed up build
CONFIG_MODULES=n
CONFIG_SMP=n
CONFIG_PM=n
CONFIG_ACPI=n
CONFIG_USB=n
CONFIG_NET=n
CONFIG_WIRELESS=n
CONFIG_SOUND=n
CONFIG_INPUT=n
CONFIG_FRAMEBUFFER_CONSOLE=n
CONFIG_VT=n
CONFIG_PRINTK=y
CONFIG_PRINTK_TIME=y
EOF
  
  # Clean and configure
  make olddefconfig
  
  log "Kernel configured"
}

build_kernel() {
  local kernel_dir="$BUILD_DIR/linux-$KERNEL_VERSION"
  local vmlinux="$IMAGES_DIR/vmlinux"
  local bzimage="$IMAGES_DIR/bzImage"
  
  if [[ -f "$vmlinux" && -f "$bzimage" ]]; then
    log "Kernel already built"
    return 0
  fi
  
  log "Building kernel (this will take 10-30 minutes)"
  
  cd "$kernel_dir"
  
  # Build vmlinux for firecracker
  if [[ ! -f "$vmlinux" ]]; then
    log "Building vmlinux for firecracker"
    make -j"$(nproc)" vmlinux
    cp vmlinux "$vmlinux"
    log "Built: $vmlinux"
    ls -lh "$vmlinux"
  fi
  
  # Build bzImage for kvmtool and crosvm
  if [[ ! -f "$bzimage" ]]; then
    log "Building bzImage for kvmtool and crosvm"
    make -j"$(nproc)" bzImage
    cp arch/x86/boot/bzImage "$bzimage"
    log "Built: $bzimage"
    ls -lh "$bzimage"
  fi
}

create_minimal_rootfs() {
  log "Creating minimal rootfs with busybox"
  
  local rootfs_dir="$IMAGES_DIR/rootfs"
  rm -rf "$rootfs_dir"
  mkdir -p "$rootfs_dir"/{bin,sbin,etc,proc,sys,dev,tmp,root,lib,lib64}
  
  # Copy busybox and create symlinks
  cp "$(which busybox)" "$rootfs_dir/bin/busybox"
  cd "$rootfs_dir/bin"
  for cmd in sh ls cat echo mount umount mkdir rm cp mv ps grep find dmesg uname hostname poweroff reboot halt sleep; do
    ln -sf busybox "$cmd"
  done
  cd "$rootfs_dir/sbin"
  for cmd in init poweroff reboot halt; do
    ln -sf ../bin/busybox "$cmd"
  done
  cd "$ROOT_DIR"
  
  # Copy dynamic libraries if busybox is dynamically linked
  if ldd "$(which busybox)" 2>/dev/null | grep -q "not a dynamic executable"; then
    log "BusyBox is statically linked, no libraries needed"
  else
    log "BusyBox is dynamically linked, copying libraries"
    ldd "$(which busybox)" 2>/dev/null | grep -oP '/\S+' | while read -r lib; do
      if [[ -f "$lib" ]]; then
        local dest_dir="$rootfs_dir$(dirname "$lib")"
        mkdir -p "$dest_dir"
        cp -L "$lib" "$dest_dir/"
        log "Copied $lib"
      fi
    done
  fi
  
  # Create init script
  cat > "$rootfs_dir/init" <<'EOF'
#!/bin/sh
# Write marker to both stdout and /dev/console for maximum compatibility
echo "VM init started"
echo "VM init started" > /dev/console 2>/dev/null || true

# Mount filesystems (ignore errors)
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# Write success marker
echo "VM boot successful!"
echo "VM boot successful!" > /dev/console 2>/dev/null || true
echo "Kernel: $(uname -r)"
echo "Hostname: $(hostname)"

# Small delay to ensure output is flushed before poweroff
sleep 1

# Force immediate poweroff
poweroff -f
EOF
  chmod +x "$rootfs_dir/init"
  
  echo "$rootfs_dir"
}

create_ext4_image() {
  local rootfs_dir="$1"
  local image_path="$2"
  
  log "Creating ext4 image: $image_path"
  
  # Create empty image
  dd if=/dev/zero of="$image_path" bs=1M count="$ROOTFS_SIZE_MB" status=none
  
  # Format as ext4
  /usr/sbin/mkfs.ext4 -F -d "$rootfs_dir" "$image_path" >/dev/null 2>&1
  
  log "Created $image_path ($ROOTFS_SIZE_MB MB)"
}

create_config() {
  log "Creating config.json"
  
  cat > "$ROOT_DIR/config.json" <<EOF
{
  "project_dir": ".",
  "timeout_seconds": 6,
  "boot_timeout_seconds": 30,
  "firecracker": {
    "binary": "firecracker",
    "kernel_image": "$IMAGES_DIR/vmlinux",
    "rootfs_image": "$IMAGES_DIR/rootfs.ext4",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw rootwait init=/init",
    "vcpu_count": 1,
    "mem_size_mib": 128
  },
  "kvmtool": {
    "binary": "lkvm",
    "kernel_image": "$IMAGES_DIR/bzImage",
    "rootfs_image": "$IMAGES_DIR/rootfs.ext4",
    "boot_args": "console=ttyS0 reboot=k panic=1 root=/dev/vda rw rootwait init=/init",
    "vcpu_count": 1,
    "mem_size_mib": 128
  },
  "crosvm": {
    "binary": "crosvm",
    "kernel_image": "$IMAGES_DIR/bzImage",
    "rootfs_image": "$IMAGES_DIR/rootfs.ext4",
    "boot_args": "console=ttyS0 reboot=k panic=1 root=/dev/vda rw rootwait init=/init",
    "vcpu_count": 1,
    "mem_size_mib": 128
  }
}
EOF
  
  log "Created config.json"
}

main() {
  log "Building minimal VM images"
  log "This will take 15-45 minutes depending on your system"
  
  install_build_deps
  download_kernel
  configure_kernel
  build_kernel
  
  local rootfs_dir
  rootfs_dir="$(create_minimal_rootfs)"
  
  create_ext4_image "$rootfs_dir" "$IMAGES_DIR/rootfs.ext4"
  create_config
  
  log "Images created in $IMAGES_DIR:"
  ls -lh "$IMAGES_DIR"
  
  log "You can now run the benchmark:"
  log "  PATH=\"\$HOME/.local/bin:\$PATH\" uv run python tests/bench_security.py --config config.json"
}

main "$@"
