# Findings: Firejail And MicroVMs For Agent Sandboxing

This review summarizes the current state of a local sandboxing lab for AI coding
agents. The focus is practical isolation: what sensitive host resources are hidden,
which privileged actions are blocked, what resource overhead is visible, and what
must be fixed before full VM boot benchmarks can be trusted.

## Executive Summary

The Firejail-only baseline and all three host Firejail VMM profiles passed every
defensive probe that was runnable on the host. No measured stack exposed the home
secret canary, sibling project canary, session D-Bus socket, raw disk path, tmpfs
mount, or user namespace unshare action.

The layered Firejail-plus-microVM design remains the stronger security model on
paper because an agent must cross guest Firejail, the guest kernel boundary, the
VMM boundary, and host Firejail before reaching the host session. However, real VM
boot measurements are still blocked because `/dev/kvm` is not present and Linux
does not currently see a `vmx` or `svm` CPU virtualization flag.

## Tested Environment State

| Check | Result | Interpretation |
| --- | --- | --- |
| Firejail binary | Pass | `/usr/bin/firejail` is available |
| Firecracker binary | Pass | User-local binary is available |
| kvmtool/lkvm binary | Pass | User-local binary is available |
| crosvm binary | Pass | User-local binary is available |
| User in `kvm` group | Pass | Group membership is present after restart |
| `/dev/kvm` | Fail | KVM device does not exist |
| CPU virtualization flag | Fail | Neither `vmx` nor `svm` is visible |
| Guest kernel/rootfs images | Skip | Image paths are not configured |

```text
Host Readiness
pass  ####      firejail, VMM binaries, kvm group
fail  ###       cpu virtualization flag, /dev/kvm, loaded KVM module
skip  ########  vendor module unknown, unconfigured guest images
```

## Probe Results

| Stack | Pass | Fail | Skip | Notes |
| --- | ---: | ---: | ---: | --- |
| Firejail only | 10 | 0 | 4 | No VMM step; `/dev/kvm` absent |
| Firecracker host profile | 11 | 0 | 3 | Binary runs under host Firejail; VM boot skipped |
| kvmtool host profile | 11 | 0 | 3 | `lkvm` usage exit accepted; VM boot skipped |
| crosvm host profile | 11 | 0 | 3 | Binary runs under host Firejail; VM boot skipped |

```text
Pass Count
firejail-only  ##########   10
firecracker    ###########  11
kvmtool        ###########  11
crosvm         ###########  11

Fail Count
firejail-only  0
firecracker    0
kvmtool        0
crosvm         0

Skip Count
firejail-only  ####  4
firecracker    ###   3
kvmtool        ###   3
crosvm         ###   3
```

## Security Probe Coverage

| Probe | Firejail Only | Firecracker Profile | kvmtool Profile | crosvm Profile |
| --- | --- | --- | --- | --- |
| Profile parse | Pass | Pass | Pass | Pass |
| Sandbox startup | Pass | Pass | Pass | Pass |
| Synthetic CPU/RSS workload | Pass | Pass | Pass | Pass |
| Project canary visible | Pass | Pass | Pass | Pass |
| Sibling canary blocked | Pass | Pass | Pass | Pass |
| Home secret canary blocked | Pass | Pass | Pass | Pass |
| Session D-Bus blocked | Pass | Pass | Pass | Pass |
| Docker socket blocked or absent | Skip | Skip | Skip | Skip |
| `/dev/kvm` policy | Skip | Skip | Skip | Skip |
| Raw disk blocked | Pass | Pass | Pass | Pass |
| tmpfs mount blocked | Pass | Pass | Pass | Pass |
| userns unshare blocked | Pass | Pass | Pass | Pass |
| VMM binary under Firejail | Skip | Pass | Pass | Pass |
| VM boot | Skip | Skip | Skip | Skip |

The important result is not just zero failures. It is that the probes cover common
agent escape blast-radius mistakes: accidental access to the parent workspace,
home credentials, GUI/session IPC, container daemon sockets, raw block devices,
mount, and namespace operations.

## Boundary Analysis

```text
Firejail only
agent process
  -> Firejail profile: filesystem, seccomp, caps, namespaces
    -> host kernel and host user session

Firejail + microVM
agent process
  -> guest Firejail profile
    -> guest kernel
      -> VMM process
        -> host Firejail profile
          -> host kernel and host user session
```

| Approach | Strength | Main Tradeoff |
| --- | --- | --- |
| Firejail only | Lightweight and easy to run | A Firejail escape reaches the host user context directly |
| Firejail + microVM | Adds guest kernel and VMM boundaries | Requires `/dev/kvm`, guest images, and more operational setup |

## Resource Results

The synthetic workload allocates 32 MiB and runs a short CPU loop. It is useful for
checking that process-tree accounting works, not for predicting full VM boot cost.

| Stack | Wall Time | CPU Time | Peak RSS | Top Process RSS | Top Process CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| Firejail only | 1042 ms | 1013 ms | 52,400 KiB | 45,108 KiB | 680 ms |
| Firecracker host profile | 883 ms | 856 ms | 49,292 KiB | 42,184 KiB | 700 ms |
| kvmtool host profile | 866 ms | 850 ms | 49,264 KiB | 42,188 KiB | 730 ms |
| crosvm host profile | 896 ms | 877 ms | 49,244 KiB | 42,212 KiB | 730 ms |

```text
Wall Time ms
firejail-only  #################################################### 1042
firecracker    ############################################          883
kvmtool        ###########################################           866
crosvm         #############################################         896

Peak RSS KiB
firejail-only  #################################################### 52400
firecracker    #################################################    49292
kvmtool        #################################################    49264
crosvm         #################################################    49244
```

The microVM profiles do not boot VMs in this measurement. These numbers represent
host Firejail profile overhead plus the synthetic workload. Once `/dev/kvm` and
guest images are configured, the VM boot path should be measured separately.

## Interpretation

The current evidence supports these conclusions:

- The Firejail profiles are effective against the local defensive probes that ran.
- The host VMM profiles are narrow enough to invoke VMM binaries while still
  blocking common host secrets and privileged operations.
- The layered microVM architecture remains preferable for high-risk agents, but it
  cannot be fully validated on this host until KVM is visible.

## Next Work

1. Fix host KVM visibility so `/dev/kvm` exists and `vmx` or `svm` is visible.
2. Add minimal guest kernel/rootfs images to `config.json`.
3. Run each VMM runner through a full boot and guest Firejail probe.

## Reproduce

```sh
uv run ruff check --fix .
uv run ruff format .
PATH="$HOME/.local/bin:$PATH" uv run python tests/check_host.py
PATH="$HOME/.local/bin:$PATH" uv run python tests/bench_security.py
```

Local generated reports are intentionally ignored by git because they include
absolute paths and process IDs specific to the test machine.
