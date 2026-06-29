#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${1:-}"
PATH="$HOME/.local/bin:$PATH"

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARNING: %s\n' "$*" >&2
}

have_cpu_virtualization() {
  grep -Eq '(vmx|svm)' /proc/cpuinfo
}

vendor_module() {
  if grep -Eq 'vmx' /proc/cpuinfo; then
    printf 'kvm_intel'
  elif grep -Eq 'svm' /proc/cpuinfo; then
    printf 'kvm_amd'
  else
    printf ''
  fi
}

run_readiness() {
  log "Running host readiness check"
  if [[ -n "$CONFIG_PATH" ]]; then
    uv run python tests/check_host.py --config "$CONFIG_PATH" || true
  else
    uv run python tests/check_host.py || true
  fi
}

run_benchmark() {
  log "Running benchmark/security probes"
  if [[ -n "$CONFIG_PATH" ]]; then
    uv run python tests/bench_security.py --config "$CONFIG_PATH"
  else
    uv run python tests/bench_security.py
  fi
}

ensure_debian_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get was not found; skipping package installation"
    return
  fi

  log "Installing Debian KVM/QEMU/libvirt packages"
  sudo apt-get update
  sudo apt-get install -y \
    bridge-utils \
    libvirt-clients \
    libvirt-daemon-system \
    qemu-system-x86 \
    qemu-utils \
    virtinst
}

load_kvm_modules() {
  local module
  module="$(vendor_module)"

  log "Loading KVM kernel modules"
  sudo modprobe kvm
  if [[ -n "$module" ]]; then
    sudo modprobe "$module"
  else
    warn "No vmx/svm CPU flag visible; cannot choose kvm_intel or kvm_amd"
  fi
}

ensure_kvm_group() {
  log "Adding current user to kvm group"
  if getent group kvm >/dev/null 2>&1; then
    sudo usermod -aG kvm "$USER"
  else
    warn "kvm group does not exist; package installation may have failed or distro differs"
  fi
}

main() {
  cd "$ROOT"

  log "Project: $ROOT"
  if [[ -n "$CONFIG_PATH" ]]; then
    log "Using config: $CONFIG_PATH"
  fi

  if ! have_cpu_virtualization; then
    warn "No vmx/svm CPU virtualization flag is visible. Enable VT-x/AMD-V in firmware or expose virtualization in the outer VM, then rerun this script. Continuing with package setup and probes."
  fi

  ensure_debian_packages
  load_kvm_modules || warn "KVM modules could not be loaded"
  ensure_kvm_group

  if [[ -e /dev/kvm ]]; then
    log "Current /dev/kvm permissions"
    ls -l /dev/kvm
  else
    warn "/dev/kvm is still missing"
  fi

  run_readiness
  run_benchmark

  log "Finished"
  if [[ ! -e /dev/kvm ]] || ! groups | grep -qw kvm; then
    warn "You may need to log out and back in after usermod, or enable virtualization in firmware, before VM boot benchmarks can pass."
  fi
}

main "$@"
