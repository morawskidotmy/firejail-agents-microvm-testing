#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARNING: %s\n' "$*" >&2
}

error() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run with sudo or as root"
  fi
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    echo "${ID,,}"
  elif command -v lsb_release >/dev/null 2>&1; then
    lsb_release -is | tr '[:upper:]' '[:lower:]'
  else
    echo "unknown"
  fi
}

check_cpu_virtualization() {
  log "Checking CPU virtualization support"
  if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
    if grep -Eq 'vmx' /proc/cpuinfo; then
      echo "Intel VT-x detected"
    else
      echo "AMD-V detected"
    fi
    return 0
  else
    warn "No CPU virtualization support detected"
    warn "Enable VT-x/AMD-V in BIOS/UEFI firmware"
    return 1
  fi
}

install_packages_debian() {
  log "Installing KVM packages (Debian/Ubuntu)"
  apt-get update
  apt-get install -y \
    qemu-kvm \
    qemu-utils \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst \
    cpu-checker
}

install_packages_fedora() {
  log "Installing KVM packages (Fedora/RHEL)"
  dnf install -y \
    qemu-kvm \
    qemu-img \
    libvirt \
    libvirt-client \
    virt-install \
    bridge-utils
}

install_packages_arch() {
  log "Installing KVM packages (Arch Linux)"
  pacman -Syu --noconfirm \
    qemu \
    libvirt \
    ebtables \
    dnsmasq \
    bridge-utils \
    virt-install
}

install_packages() {
  local distro="$1"
  case "$distro" in
    debian|ubuntu|linuxmint|pop)
      install_packages_debian
      ;;
    fedora|rhel|centos|rocky|alma)
      install_packages_fedora
      ;;
    arch|manjaro|endeavouros)
      install_packages_arch
      ;;
    *)
      warn "Unknown distribution: $distro"
      warn "Please install KVM packages manually:"
      warn "  - qemu-kvm or qemu"
      warn "  - libvirt"
      warn "  - libvirt-clients or libvirt-client"
      warn "  - virt-install"
      return 1
      ;;
  esac
}

load_kvm_modules() {
  log "Loading KVM kernel modules"
  
  modprobe kvm || error "Failed to load kvm module"
  
  if grep -Eq 'vmx' /proc/cpuinfo; then
    modprobe kvm_intel || error "Failed to load kvm_intel module"
    echo "Loaded kvm and kvm_intel modules"
  elif grep -Eq 'svm' /proc/cpuinfo; then
    modprobe kvm_amd || error "Failed to load kvm_amd module"
    echo "Loaded kvm and kvm_amd modules"
  else
    error "No CPU virtualization support detected"
  fi
}

make_modules_persistent() {
  log "Making KVM modules load on boot"
  local modules_file="/etc/modules-load.d/kvm.conf"
  
  if [[ ! -f "$modules_file" ]]; then
    cat > "$modules_file" <<EOF
kvm
kvm_intel
kvm_amd
EOF
    echo "Created $modules_file"
  else
    echo "Modules file already exists: $modules_file"
  fi
}

setup_kvm_group() {
  log "Setting up kvm group access"
  
  if ! getent group kvm >/dev/null 2>&1; then
    warn "kvm group does not exist"
    return 1
  fi
  
  local user="${SUDO_USER:-$USER}"
  if id -nG "$user" | grep -qw kvm; then
    echo "User $user is already in kvm group"
  else
    usermod -aG kvm "$user"
    echo "Added $user to kvm group"
    warn "You must log out and back in for group changes to take effect"
  fi
}

setup_libvirt() {
  log "Starting and enabling libvirtd service"
  
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable libvirtd
    systemctl start libvirtd
    echo "libvirtd service started and enabled"
  else
    warn "systemctl not available; start libvirtd manually"
  fi
}

verify_kvm() {
  log "Verifying KVM setup"
  
  if [[ ! -e /dev/kvm ]]; then
    warn "/dev/kvm does not exist"
    return 1
  fi
  
  echo "/dev/kvm exists:"
  ls -l /dev/kvm
  
  local user="${SUDO_USER:-$USER}"
  if [[ -w /dev/kvm ]]; then
    echo "User $user can access /dev/kvm"
  else
    warn "User $user cannot write to /dev/kvm"
    warn "Check permissions: $ ls -l /dev/kvm"
  fi
  
  if command -v kvm-ok >/dev/null 2>&1; then
    log "Running kvm-ok check"
    kvm-ok || true
  fi
  
  return 0
}

print_summary() {
  log "KVM Setup Summary"
  echo ""
  echo "KVM has been configured on your system."
  echo ""
  echo "Next steps:"
  echo "  1. Log out and log back in (for group membership)"
  echo "  2. Verify with: ls -l /dev/kvm"
  echo "  3. Test with: qemu-system-x86_64 --version"
  echo ""
  echo "For the vm-firejail-lab project:"
  echo "  - Edit config.json with kernel/rootfs paths"
  echo "  - Run: PATH=\"\$HOME/.local/bin:\$PATH\" uv run python tests/bench_security.py --config config.json"
  echo ""
}

main() {
  check_root
  
  local distro
  distro="$(detect_distro)"
  log "Detected distribution: $distro"
  
  if ! check_cpu_virtualization; then
    error "CPU virtualization is not available. Enable it in BIOS/UEFI."
  fi
  
  install_packages "$distro" || warn "Package installation had issues"
  load_kvm_modules
  make_modules_persistent
  setup_kvm_group || warn "kvm group setup had issues"
  setup_libvirt || warn "libvirtd setup had issues"
  
  if verify_kvm; then
    print_summary
  else
    warn "KVM verification failed"
    warn "You may need to reboot the system"
  fi
}

main "$@"
