# Firecracker

Firecracker is a lightweight virtual machine monitor (VMM) developed by AWS, designed for creating and managing secure, multi-tenant container and function-based services.

## Architecture

```
Host Firejail Sandbox
  └─> firecracker process (sandboxed)
      └─> KVM-accelerated microVM
          └─> Guest kernel + init
```

## Performance

- **Boot time:** 1,981 ms (middle)
- **Peak RSS:** 56,776 KiB (lowest of all VMMs)
- **CPU time:** 310 ms (lowest)

## Strengths

- **Lowest memory footprint:** Uses ~56 MB peak RSS, significantly less than kvmtool (75 MB) and crosvm (64 MB)
- **Production-hardened:** Developed and used at scale by AWS for Lambda and Fargate
- **Minimal attack surface:** Stripped-down device model reduces potential vulnerabilities
- **Strong isolation:** Designed specifically for multi-tenant security
- **API-driven:** REST API allows programmatic control and automation
- **Jailer integration:** Built-in jailer provides additional process isolation and resource constraints

## Weaknesses

- **Slower boot than kvmtool:** 1.5s vs 0.9s for kvmtool
- **Complex configuration:** Requires JSON config file and API socket management
- **Limited device model:** Minimal device support by design (no PCI, limited USB, etc.)
- **Firecracker-specific kernel requirements:** Needs specific kernel config options (virtio-mmio, no PCI)
- **Less ergonomic for development:** Not designed for interactive use or debugging
- **API overhead:** Requires socket communication for VM lifecycle management

## Best Use Cases

- **Security-critical agent isolation:** When you need the strongest isolation guarantees
- **Multi-tenant environments:** Running multiple untrusted agents with strict resource limits
- **Production deployments:** Where AWS's production experience and security model matter
- **Minimal footprint requirements:** When memory usage is the primary constraint

## Configuration Notes

Firecracker requires:
- `vmlinux` kernel (ELF format, not bzImage)
- Kernel compiled with `CONFIG_VIRTIO_MMIO=y` and `CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y`
- `pci=off` in boot args (Firecracker doesn't support PCI)
- JSON config file specifying boot source, drives, and machine config
- API socket for VM lifecycle control

## Security Model

Firecracker provides defense in depth:
1. **Host Firejail:** Sandboxes the firecracker process itself
2. **KVM isolation:** Hardware-enforced VM boundary
3. **Minimal device model:** Reduces kernel attack surface in guest
4. **Jailer (optional):** Additional cgroup/namespace isolation for firecracker process

The combination of host Firejail + Firecracker's minimal device model provides strong isolation, though the API surface adds complexity.

## Comparison

- **vs kvmtool:** Firecracker uses 25% less memory but takes 154% longer to boot
- **vs crosvm:** Firecracker uses 12% less memory and takes 1.6% less time to boot
- **vs Firejail-only:** Adds VM isolation layer but requires KVM and more resources

## Verdict

Firecracker is the right choice when security and memory efficiency are paramount, and you're willing to accept slower boot times and configuration complexity. It's production-ready and battle-tested at scale, making it suitable for serious deployments where isolation guarantees matter more than developer ergonomics.
