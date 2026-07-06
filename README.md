# Firejail Agents MicroVM Testing

Compare practical sandboxing strategies for AI coding agents: a lightweight
Firejail-only baseline versus layered Firejail-plus-microVM stacks with
Firecracker, kvmtool/lkvm, and crosvm.

The lab is designed for defensive measurement. It checks what a sandbox can see,
which privileged actions are blocked, how much CPU/RSS a small workload consumes,
and which host prerequisites are missing before real VM boot tests can run.

> [!IMPORTANT]
> These probes are not exploit payloads. They are policy and isolation checks for
> local development environments that run untrusted or semi-trusted coding agents.

## What Is Tested

| Approach | Boundary Model | Current Status |
| --- | --- | --- |
| Firejail only | agent -> Firejail -> host kernel | Measured |
| Firejail + Firecracker | VMM -> Firejail -> host kernel | Measured |
| Firejail + kvmtool | VMM -> Firejail -> host kernel | Measured |
| Firejail + crosvm | VMM -> Firejail -> host kernel | Measured |

> **Note:** The current benchmark measures host Firejail wrapping the VMM process, which then boots a minimal VM. Guest Firejail profiles exist in `guest-profiles/` but are not yet integrated into the automated boot benchmark.

```text
Layered microVM target

host firejail sandbox
  -> VMM process: firecracker | lkvm | crosvm
    -> minimal guest VM
      -> guest firejail sandbox
        -> AI coding agent or probe payload
```

## Key Findings

Latest local run:

```text
Probe Results
firejail-only              ############   pass 12 | fail 0 | skip 2
firecracker                ############## pass 14 | fail 0 | skip 0
kvmtool                    ############## pass 14 | fail 0 | skip 0
crosvm                     ############## pass 14 | fail 0 | skip 0
crosvm-no-disable-sandbox  #############  pass 13 | fail 1 | skip 0
```

All measured Firejail profiles blocked the sensitive local paths and privileged
actions covered by the harness. The VMM binaries were also invoked successfully
under their host Firejail profiles. All three VMMs successfully boot minimal
guest VMs with KVM acceleration.

The crosvm-no-disable-sandbox configuration fails because crosvm's built-in
minijail conflicts with Firejail. See [crosvm Sandbox Configuration](#crosvm-sandbox-configuration)
for details.

## VM Boot Performance

Measured time from VMM launch to guest init printing "VM boot successful!" marker:

| VMM | Boot Time | Peak RSS | CPU Time |
| --- | ---: | ---: | ---: |
| kvmtool | 779 ms | 75,928 KiB | 410 ms |
| crosvm | 2,014 ms | 64,528 KiB | 1,030 ms |
| Firecracker | 1,981 ms | 56,776 KiB | 310 ms |

```text
Boot Time (ms)
kvmtool        ####################### 779
firecracker    ############################################### 1981
crosvm         ################################################ 2014
```

kvmtool boots fastest at 779ms, while Firecracker uses the least memory at
56,776 KiB peak RSS. All three VMMs complete boot within 2 seconds under
Firejail sandboxing.

See [docs/firecracker.md](docs/firecracker.md), [docs/kvmtool.md](docs/kvmtool.md),
and [docs/crosvm.md](docs/crosvm.md) for detailed analysis of each VMM.

### Guest Probe

The benchmark now captures a **direct guest shell probe** (`tests/guest_probe.sh`)
that runs inside each minimal VM during boot. The probe reports what the guest
environment can see (devices, sensitive paths, network files, Firejail availability).

```text
host firejail sandbox
  -> VMM process: firecracker | lkvm | crosvm
    -> minimal guest VM
      -> /init -> /guest_probe.sh  (direct shell probe, captured in results)
```

The guest probe confirms that all three VMMs boot successfully and the probe
output is parsed into `results/latest.json` under each `vm_boot` measurement.

**Guest Firejail is future work.** Running Firejail inside the minimal busybox
rootfs currently fails due to missing shared libraries (`libapparmor.so.1`,
`libselinux.so.1`, `libpcre2-8.so.0`) and runtime directories. A richer guest
rootfs with Python and full Firejail support is needed for the full layered
model: host Firejail → VMM → guest kernel → guest Firejail → agent.

## crosvm Sandbox Configuration

crosvm includes its own sandboxing layer (minijail) that conflicts with Firejail.
The benchmark tests both configurations:

| Configuration | Boot Time | Peak RSS | CPU Time | Status |
| --- | ---: | ---: | ---: | ---: |
| crosvm with `--disable-sandbox` | 2,014 ms | 64,528 KiB | 1,030 ms | ✅ Pass |
| crosvm without `--disable-sandbox` | — | — | — | ❌ Fail |

**Why `--disable-sandbox` is required:**

crosvm's built-in minijail attempts to create a jail environment that conflicts
with Firejail's sandboxing. Without `--disable-sandbox`, crosvm fails with:

```
ERROR crosvm: exiting with error 1: "/var/empty" is not a directory, cannot create jail
```

The host Firejail profile provides the active sandboxing layer for crosvm in this
benchmark. crosvm's internal minijail sandboxing is disabled to avoid conflicts.
Note that Firejail and minijail have different security models and coverage; this
benchmark measures the Firejail layer, not the combined effect of both.

**Recommendation:** Use `--disable-sandbox` when running crosvm under Firejail.
For production deployments, evaluate whether Firejail's policies meet your security
requirements, or consider running crosvm with its native minijail outside of Firejail.

## Resource Snapshot

The synthetic workload allocates 32 MiB and burns CPU briefly inside each profile.

| Stack | Wall Time | CPU Time | Peak RSS | Top Process RSS |
| --- | ---: | ---: | ---: | ---: |
| Firejail only | 1,073 ms | 1,028 ms | 52,552 KiB | 45,192 KiB |
| Firecracker host profile | 859 ms | 828 ms | 49,260 KiB | 42,124 KiB |
| kvmtool host profile | 832 ms | 824 ms | 48,972 KiB | 42,192 KiB |
| crosvm host profile | 855 ms | 830 ms | 49,212 KiB | 42,244 KiB |

```text
Peak RSS KiB
firejail-only  #################################################### 52552
firecracker    #################################################    49260
kvmtool        #################################################    48972
crosvm         #################################################    49212
```

## Project Layout

```text
baseline-profiles/   Firejail-only baseline profile
host-profiles/       Firejail profiles for host-side VMM processes
guest-profiles/      Firejail profiles to install inside guest VMs
runners/             Wrapper scripts for Firecracker, kvmtool, and crosvm
tests/               Host readiness and sandbox probe harnesses
docs/                Findings and publish plan
scripts/             Host setup helpers
results/             Local generated reports, ignored by git
```

## Quick Start

Install Python tooling with `uv`, then run the checks:

```sh
uv run ruff check --fix .
uv run ruff format .
PATH="$HOME/.local/bin:$PATH" uv run python tests/check_host.py
PATH="$HOME/.local/bin:$PATH" uv run python tests/bench_security.py
```

Generated reports are written locally to `results/latest.json` and
`results/latest.md`. They are intentionally ignored by git because they include
host-specific absolute paths and process IDs.

## Enable KVM On Debian

KVM is a kernel acceleration interface exposed as `/dev/kvm`. Firecracker,
kvmtool, and crosvm need that device for real VM boot tests.

```sh
grep -E '(vmx|svm)' /proc/cpuinfo | head
ls -l /dev/kvm
groups | grep -w kvm
```

Install normal Debian KVM/QEMU/libvirt tooling:

```sh
sudo apt update
sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst bridge-utils
sudo modprobe kvm
sudo modprobe kvm_intel   # Intel
# sudo modprobe kvm_amd   # AMD instead
sudo usermod -aG kvm "$USER"
```

Log out and back in after `usermod`.

The project helper performs the same setup steps and reruns the lab:

```sh
scripts/enable-kvm-and-run.sh
```

With configured VM image paths:

```sh
scripts/enable-kvm-and-run.sh config.json
```

## Configure VM Boot Inputs

Build minimal VM images (kernel + rootfs) for all three VMMs:

```sh
scripts/build-vm-images.sh
```

This downloads Linux kernel 6.1.110, builds it with minimal config for VM boot,
creates a busybox-based rootfs, and generates `config.json` with the correct paths.
The build takes 15-45 minutes depending on your system.

Alternatively, copy the example config and set kernel/rootfs paths manually:

```sh
cp config.example.json config.json
PATH="$HOME/.local/bin:$PATH" uv run python tests/bench_security.py --config config.json
```

The runner scripts expect images to be inside this project directory or otherwise
explicitly whitelisted by the caller.

### VM Boot Configuration

The benchmark now includes real VM boot probes when `/dev/kvm` is available and
kernel/rootfs images are configured. Edit `config.json` to specify:

```json
{
  "project_dir": ".",
  "timeout_seconds": 6,
  "boot_timeout_seconds": 30,
  "firecracker": {
    "binary": "firecracker",
    "kernel_image": "/path/to/vmlinux",
    "rootfs_image": "/path/to/rootfs.ext4",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off",
    "vcpu_count": 1,
    "mem_size_mib": 128
  }
}
```

The `project_dir` field resolves relative paths in the config. The boot probe will:

1. Generate VMM-specific configuration (Firecracker JSON config, kvmtool/crosvm CLI args)
2. Launch the VMM under Firejail with the configured kernel and rootfs
3. Measure boot time and resource usage
4. Report success/failure/timeout

Without `/dev/kvm` or configured images, the boot probe is skipped.

## Read The Review

The full article-style review with charts and interpretation is in
`docs/findings.md`.
