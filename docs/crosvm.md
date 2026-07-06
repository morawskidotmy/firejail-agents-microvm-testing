# crosvm

crosvm (Chrome OS Virtual Machine Monitor) is a lightweight VMM developed by Google, designed for running Linux guests with a focus on security and sandboxing.

## Architecture

```
Host Firejail Sandbox
  └─> crosvm process (sandboxed)
      └─> KVM-accelerated VM
          └─> Guest kernel + init
```

## Performance

- **Boot time:** 2,014 ms (slowest)
- **Peak RSS:** 64,528 KiB (middle)
- **CPU time:** 1,030 ms (highest)

### Sandbox Configuration Impact

The benchmark tests crosvm with and without `--disable-sandbox`:

| Configuration | Boot Time | Peak RSS | CPU Time | Status |
| --- | ---: | ---: | ---: | ---: |
| with `--disable-sandbox` | 1,387 ms | 64,520 KiB | 980 ms | ✅ Pass |
| without `--disable-sandbox` | — | — | — | ❌ Fail |

Without `--disable-sandbox`, crosvm fails immediately with:
```
ERROR crosvm: exiting with error 1: "/var/empty" is not a directory, cannot create jail
```

This occurs because crosvm's built-in minijail sandboxing conflicts with Firejail's
sandboxing. The `--disable-sandbox` flag is required when running crosvm under Firejail.

## Strengths

- **Strong security heritage:** Developed by Google with security as a primary concern
- **ChromeOS production use:** Battle-tested in ChromeOS for running Linux apps
- **Balanced resource usage:** Middle ground between Firecracker (low memory) and kvmtool (high memory)
- **Sandboxing focus:** Designed to work within sandboxed environments
- **PCI support:** Full PCI device model for hardware compatibility
- **Active development:** Backed by Google with ongoing improvements

## Weaknesses

- **Middle performance:** Boot time and CPU usage are between Firecracker and kvmtool
- **Complex setup:** Requires specific configuration and sandboxing considerations
- **Less flexible:** Some features require specific kernel configs or workarounds
- **Smaller community:** Less community adoption compared to Firecracker
- **ChromeOS-centric:** Some features optimized for ChromeOS use cases
- **Sandbox conflicts:** Native minijail conflicts with Firejail, requiring `--disable-sandbox`

## Best Use Cases

- **Security-focused deployments:** When Google's security model and ChromeOS hardening matter
- **Balanced resource constraints:** When you need middle-ground memory usage
- **ChromeOS integration:** For projects targeting ChromeOS or similar environments
- **Long-running VMs:** Where boot time is less critical than runtime security
- **Enterprise environments:** Where Google's backing and security focus are valued

## Configuration Notes

crosvm requires:
- `bzImage` kernel format (standard x86 boot format)
- Kernel compiled with `CONFIG_VIRTIO_PCI=y` for PCI-based virtio devices
- Command-line arguments: `--cpus`, `--mem`, `--params`, `--block`
- Block device specified as `path=<rootfs>,root`
- **`--disable-sandbox` flag when running under Firejail** (see Security Model below)
- Serial console output captured via stdout

## Security Model

crosvm provides defense in depth:
1. **Host Firejail:** Sandboxes the crosvm process itself (primary security layer in this benchmark)
2. **KVM isolation:** Hardware-enforced VM boundary
3. **ChromeOS hardening:** Security features from ChromeOS development

### Why `--disable-sandbox` is Required

crosvm includes its own sandboxing layer (minijail) that creates a restricted
environment for device processes. When running under Firejail, this causes a
conflict:

- crosvm's minijail attempts to create a jail using `/var/empty` as a pivot root
- Firejail's sandbox restricts filesystem access and namespace operations
- The two sandboxing layers compete, causing crosvm to fail immediately

**Solution:** Use `--disable-sandbox` to disable crosvm's internal minijail
sandboxing. The host Firejail profile provides the active sandboxing layer:

- Seccomp filters block dangerous syscalls
- Capabilities are dropped (nonewprivs, caps.drop all)
- Filesystem blacklists prevent access to sensitive paths
- Namespace isolation (private-tmp, disable-mnt, machine-id)
- Protocol restrictions (nosound, novideo, noinput, nodbus)

**Security implication:** Disabling crosvm's internal sandbox means the Firejail
profile becomes the primary sandboxing layer. Firejail and minijail have different
security models and coverage. This benchmark measures the Firejail layer, not the
combined effect of both. For production deployments, evaluate whether Firejail's
policies meet your security requirements.

**Recommendation:** Use `--disable-sandbox` when running crosvm under Firejail.
For alternative configurations, consider running crosvm with its native minijail
outside of Firejail to leverage both sandboxing layers.

## Comparison

- **vs Firecracker:** crosvm uses 14% more memory but takes 1.7% longer to boot
- **vs kvmtool:** crosvm uses 15% less memory but takes 158% longer to boot
- **vs Firejail-only:** Adds VM isolation with strong security model but higher CPU overhead

## Verdict

crosvm is the right choice when you value Google's security expertise and ChromeOS hardening, and you're willing to accept moderate boot times and CPU usage. It's well-suited for production environments where security is paramount and boot time is less critical.

The balanced resource usage makes crosvm suitable for:
- Production agent deployments with strict security requirements
- Environments where Google's security model is trusted
- Long-running VMs where boot time is amortized
- Enterprise deployments with ChromeOS integration needs

However, for fast iteration or memory-constrained environments, Firecracker or kvmtool would be better choices.
