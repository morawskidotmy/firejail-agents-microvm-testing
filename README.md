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
| Firejail + Firecracker | agent -> guest Firejail -> guest kernel -> Firecracker -> host Firejail | Measured until VM boot prerequisite |
| Firejail + kvmtool | agent -> guest Firejail -> guest kernel -> lkvm -> host Firejail | Measured until VM boot prerequisite |
| Firejail + crosvm | agent -> guest Firejail -> guest kernel -> crosvm -> host Firejail | Measured until VM boot prerequisite |

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
firejail-only  ##########   pass 10 | fail 0 | skip 4
firecracker    ###########  pass 11 | fail 0 | skip 3
kvmtool        ###########  pass 11 | fail 0 | skip 3
crosvm         ###########  pass 11 | fail 0 | skip 3
```

All measured Firejail profiles blocked the sensitive local paths and privileged
actions covered by the harness. The VMM binaries were also invoked successfully
under their host Firejail profiles.

The remaining blockers are host prerequisites, not profile failures:

```text
Host Readiness
KVM group        pass: current user is in kvm group
/dev/kvm         fail: device is absent
vmx/svm flags    fail: CPU virtualization flag not visible to Linux
guest images     skip: kernel/rootfs images not configured
```

> [!NOTE]
> Real VM boot overhead is intentionally not claimed yet. `/dev/kvm` is still
> absent on the tested host, so Firecracker, kvmtool, and crosvm can be checked as
> binaries under Firejail but cannot boot hardware-accelerated guests here.

## Resource Snapshot

The synthetic workload allocates 32 MiB and burns CPU briefly inside each profile.

| Stack | Wall Time | CPU Time | Peak RSS | Top Process RSS |
| --- | ---: | ---: | ---: | ---: |
| Firejail only | 1042 ms | 1013 ms | 52,400 KiB | 45,108 KiB |
| Firecracker host profile | 883 ms | 856 ms | 49,292 KiB | 42,184 KiB |
| kvmtool host profile | 866 ms | 850 ms | 49,264 KiB | 42,188 KiB |
| crosvm host profile | 896 ms | 877 ms | 49,244 KiB | 42,212 KiB |

```text
Peak RSS KiB
firejail-only  #################################################### 52400
firecracker    #################################################    49292
kvmtool        #################################################    49264
crosvm         #################################################    49244
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

Copy the example config and set kernel/rootfs paths for each VMM:

```sh
cp config.example.json config.json
PATH="$HOME/.local/bin:$PATH" uv run python tests/bench_security.py --config config.json
```

The runner scripts expect images to be inside this project directory or otherwise
explicitly whitelisted by the caller.

## Read The Review

The full article-style review with charts and interpretation is in
`docs/findings.md`.
