# Findings: Firejail And MicroVMs For Agent Sandboxing

This review summarizes the current state of a local sandboxing lab for AI coding
agents. The focus is practical isolation: what sensitive host resources are hidden,
which privileged actions are blocked, what resource overhead is visible, and what
the full VM boot benchmark reveals.

## Executive Summary

The Firejail-only baseline and all three host Firejail VMM profiles passed every
defensive probe that was runnable on the host. No measured stack exposed the home
secret canary, sibling project canary, session D-Bus socket, raw disk path, tmpfs
mount, or user namespace unshare action.

All three VMMs (Firecracker, kvmtool, crosvm) successfully boot minimal guest VMs
under Firejail sandboxing with KVM acceleration. The layered Firejail-plus-microVM
design provides stronger isolation than Firejail-only, though guest Firejail
integration is not yet automated.

The crosvm-no-disable-sandbox configuration fails because crosvm's built-in
minijail conflicts with Firejail's sandboxing. This is documented and expected.

## Tested Environment State

| Check | Result | Interpretation |
| --- | --- | --- |
| Firejail binary | Pass | `/usr/bin/firejail` is available |
| Firecracker binary | Pass | User-local binary is available |
| kvmtool/lkvm binary | Pass | User-local binary is available |
| crosvm binary | Pass | User-local binary is available |
| User in `kvm` group | Pass | Group membership is present |
| `/dev/kvm` | Pass | KVM device exists and is accessible |
| CPU virtualization flag | Pass | `vmx` or `svm` is visible |
| Guest kernel/rootfs images | Pass | Images are built and configured |

```text
Host Readiness
pass  ############  all prerequisites met
```

## Probe Results

| Stack | Pass | Fail | Skip | Notes |
| --- | ---: | ---: | ---: | --- |
| Firejail only | 12 | 0 | 2 | No VMM step |
| Firecracker host profile | 14 | 0 | 0 | VM boots successfully |
| kvmtool host profile | 14 | 0 | 0 | VM boots successfully |
| crosvm host profile | 14 | 0 | 0 | VM boots with --disable-sandbox |
| crosvm-no-disable-sandbox | 13 | 1 | 0 | VM boot fails due to minijail conflict |

```text
Pass Count
firejail-only              ############   12
firecracker                ############## 14
kvmtool                    ############## 14
crosvm                     ############## 14
crosvm-no-disable-sandbox  #############  13

Fail Count
firejail-only              0
firecracker                0
kvmtool                    0
crosvm                     0
crosvm-no-disable-sandbox  1
```

## Security Probe Coverage

| Probe | Firejail Only | Firecracker | kvmtool | crosvm | crosvm (no --disable-sandbox) |
| --- | --- | --- | --- | --- | --- |
| Profile parse | Pass | Pass | Pass | Pass | Pass |
| Sandbox startup | Pass | Pass | Pass | Pass | Pass |
| Synthetic CPU/RSS workload | Pass | Pass | Pass | Pass | Pass |
| Project canary visible | Pass | Pass | Pass | Pass | Pass |
| Sibling canary blocked | Pass | Pass | Pass | Pass | Pass |
| Home secret canary blocked | Pass | Pass | Pass | Pass | Pass |
| Session D-Bus blocked | Pass | Pass | Pass | Pass | Pass |
| Docker socket blocked | Pass | Pass | Pass | Pass | Pass |
| `/dev/kvm` policy | Pass | Pass | Pass | Pass | Pass |
| Raw disk blocked | Pass | Pass | Pass | Pass | Pass |
| tmpfs mount blocked | Pass | Pass | Pass | Pass | Pass |
| userns unshare blocked | Pass | Pass | Pass | Pass | Pass |
| VMM binary under Firejail | Skip | Pass | Pass | Pass | Pass |
| VM boot | Skip | Pass | Pass | Pass | Fail |

The important result is not just zero failures in the working configurations. It is
that the probes cover common agent escape blast-radius mistakes: accidental access
to the parent workspace, home credentials, GUI/session IPC, container daemon sockets,
raw block devices, mount, and namespace operations.

## VM Boot Performance

Measured time from VMM launch to guest init printing "VM boot successful!" marker:

| VMM | Boot Time | Peak RSS | CPU Time | Status |
| --- | ---: | ---: | ---: | --- |
| kvmtool | 820 ms | 67,960 KiB | 380 ms | ✅ Fastest boot |
| crosvm | 1,389 ms | 64,736 KiB | 980 ms | ✅ Middle ground |
| Firecracker | 1,998 ms | 45,320 KiB | 280 ms | ✅ Lowest memory |
| crosvm (no --disable-sandbox) | — | — | — | ❌ Fails immediately |

```text
Boot Time (ms)
kvmtool        ########################## 820
crosvm         ############################################### 1389
firecracker    ######################################################### 1998

Peak RSS (KiB)
firecracker    ############################################ 45320
crosvm         ############################################## 64736
kvmtool        #################################################### 67960

CPU Time (ms)
firecracker    #################### 280
kvmtool        ######################## 380
crosvm         ############################################################ 980
```

**Key findings:**
- **kvmtool** boots fastest (820ms) but uses the most memory (67,960 KiB)
- **Firecracker** uses the least memory (45,320 KiB) and lowest CPU (280ms)
- **crosvm** provides balanced performance but requires `--disable-sandbox` under Firejail
- All three VMMs complete boot within 2 seconds under Firejail sandboxing

## Guest Probe Results

The benchmark captures a **direct guest shell probe** (`tests/guest_probe.sh`) that
runs inside each minimal VM during boot. The probe reports what the guest environment
can see:

| Check | Result | Interpretation |
| --- | --- | --- |
| `/dev/vda` exists | true | Virtio block device is visible |
| `/dev/kvm` exists | false | No nested KVM in guest |
| `/dev/sda` exists | false | No SCSI device |
| `/etc/shadow` readable | false | Shadow file is not exposed |
| `/proc/kcore` readable | true | proc/kcore is accessible in guest |
| `~/.ssh` exists | false | No SSH keys in guest |
| `~/.aws` exists | false | No AWS credentials in guest |
| `~/.gnupg` exists | false | No GPG keys in guest |
| `/proc/net/tcp` readable | false | No network stack visible |
| `/etc/resolv.conf` readable | false | No DNS configuration |
| Firejail binary present in guest | true | Binary exists at /usr/local/bin/firejail |
| Firejail runs in guest | false | Missing shared libraries (libapparmor, libselinux, libpcre2) |

The guest probe confirms that the minimal busybox-based VM boots successfully and
that sensitive host paths are not visible inside the guest. The probe output is
parsed into `results/latest.json` under each `vm_boot` measurement.

**Guest Firejail is future work.** The Firejail binary exists in the guest rootfs
but cannot run because the minimal busybox environment lacks required shared
libraries (`libapparmor.so.1`, `libselinux.so.1`, `libpcre2-8.so.0`) and runtime
directories. A richer guest rootfs with Python and full Firejail support is needed
for the full layered model.

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

## Resource Results

The synthetic workload allocates 32 MiB and runs a short CPU loop. It is useful for
checking that process-tree accounting works, not for predicting full VM boot cost.

| Stack | Wall Time | CPU Time | Peak RSS | Top Process RSS | Top Process CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| Firejail only | 1,073 ms | 1,028 ms | 52,552 KiB | 45,192 KiB | 690 ms |
| Firecracker host profile | 859 ms | 828 ms | 49,260 KiB | 42,124 KiB | 710 ms |
| kvmtool host profile | 832 ms | 824 ms | 48,972 KiB | 42,192 KiB | 720 ms |
| crosvm host profile | 855 ms | 830 ms | 49,212 KiB | 42,244 KiB | 700 ms |

```text
Wall Time ms
firejail-only  #################################################### 1073
firecracker    ##########################################          859
kvmtool        ########################################            832
crosvm         ##########################################          855

Peak RSS KiB
firejail-only  #################################################### 52552
firecracker    #################################################    49260
kvmtool        #################################################    48972
crosvm         #################################################    49212
```

The microVM profiles successfully boot VMs in this measurement. These numbers
represent host Firejail profile overhead plus the synthetic workload. The VM boot
path is measured separately in the vm_boot probe.

## Boundary Analysis

```text
Firejail only
agent process
  -> Firejail profile: filesystem, seccomp, caps, namespaces
    -> host kernel and host user session

Firejail + microVM (current implementation)
agent process
  -> guest kernel (minimal busybox-based)
    -> /init runs /guest_probe.sh (direct shell probe)
    -> VMM process (firecracker | lkvm | crosvm)
      -> host Firejail profile
        -> host kernel and host user session

Future: Firejail + microVM + guest Firejail
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
| Firejail + microVM + guest Firejail | Full layered isolation | Most complex setup; not yet automated |

## Interpretation

The current evidence supports these conclusions:

- The Firejail profiles are effective against the local defensive probes that ran.
- The host VMM profiles are narrow enough to invoke VMM binaries while still
  blocking common host secrets and privileged operations.
- All three VMMs successfully boot minimal guest VMs under Firejail sandboxing.
- The direct guest shell probe runs successfully and confirms sensitive host
  paths are not visible inside the guest.
- The host Firejail + VMM + guest boot architecture is validated and operational.
- Guest Firejail integration is still needed for full layered isolation.
- crosvm requires `--disable-sandbox` under Firejail due to minijail conflicts.
- Guest Firejail integration would provide the strongest isolation model but
  requires a richer guest rootfs with Python and full Firejail dependencies.

## Limitations

This benchmark has the following limitations:

1. **Single-run boot timings:** Each VMM boot test is run only once. Real-world
   performance varies; median/min/max over 5-10 runs would be more reliable.
2. **No native VMM baseline:** The benchmark measures VMMs under host Firejail.
   A native VMM baseline (without Firejail) is needed to measure Firejail overhead.
3. **No host metadata capture:** The benchmark does not record host kernel version,
   CPU model, or VMM versions. This makes results harder to reproduce or compare.
4. **No full boot logs:** Only the last 4000 characters of stdout/stderr are saved.
   Full boot logs would help diagnose failures.
5. **Guest Firejail not integrated:** The guest rootfs has a Firejail binary but it
   cannot run due to missing shared libraries. Guest isolation is not yet measured.
6. **Minimal guest environment:** The busybox-based guest has no package manager,
   no Python by default, and limited utilities. This limits guest-side testing.

## Next Work

1. Build a richer guest rootfs with Python and full Firejail support
2. Integrate guest Firejail execution into the boot benchmark
3. Create a Python guest probe to run under guest Firejail for layered isolation verification
4. Add native VMM baseline (without Firejail) to measure Firejail wrapper overhead
5. Run each boot test 5-10 times and report median/min/max
6. Add host metadata to results: kernel, CPU model, VMM versions
7. Save full boot logs per VMM, not only tails

## Reproduce

```sh
# Build VM images (one-time, takes 15-45 minutes)
scripts/build-vm-images.sh

# Run the benchmark
PATH="$HOME/.local/bin:$PATH" uv run python tests/bench_security.py --config config.json
```

Local generated reports are written to `results/latest.json` and `results/latest.md`.
They are intentionally ignored by git because they include absolute paths and process
IDs specific to the test machine.
