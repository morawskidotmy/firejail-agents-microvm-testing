# kvmtool

kvmtool (also known as lkvm) is a lightweight, minimalistic KVM-based virtual machine monitor designed for simplicity and fast boot times.

## Architecture

```
Host Firejail Sandbox
  └─> lkvm process (sandboxed)
      └─> KVM-accelerated VM
          └─> Guest kernel + init
```

## Performance

- **Boot time:** 929 ms (fastest)
- **Peak RSS:** 75,764 KiB (highest)
- **CPU time:** 510 ms

## Strengths

- **Fastest boot time:** Boots in under 1 second, 38% faster than Firecracker and 43% faster than crosvm
- **Simple CLI:** Straightforward command-line interface, no API sockets or JSON configs
- **Developer-friendly:** Designed for quick VM launches and testing
- **Flexible kernel support:** Works with both vmlinux and bzImage formats
- **PCI support:** Full PCI device model for more hardware compatibility
- **Lightweight codebase:** Minimal dependencies and simple architecture

## Weaknesses

- **Highest memory usage:** Uses ~76 MB peak RSS, 34% more than Firecracker
- **Less production-hardened:** Not designed for large-scale multi-tenant deployments
- **Weaker isolation story:** Less focus on security hardening compared to Firecracker/crosvm
- **Limited ecosystem:** Smaller community and fewer production deployments
- **Less documentation:** Fewer resources and examples compared to mainstream VMMs
- **Not designed for production:** Better suited for development and testing

## Best Use Cases

- **Fast iteration and testing:** When you need quick VM boot cycles
- **Development environments:** Where developer ergonomics matter more than isolation
- **Benchmark baselines:** Fast boot makes it good for comparative testing
- **Prototyping:** Quick VM launches for experimental work
- **Educational purposes:** Simple architecture makes it easier to understand

## Configuration Notes

kvmtool is straightforward:
- Works with `bzImage` kernel format (standard x86 boot format)
- Kernel compiled with `CONFIG_VIRTIO_PCI=y` for PCI-based virtio devices
- Simple command-line arguments: `--kernel`, `--disk`, `--cpus`, `--mem`
- No API socket or JSON config required
- Supports both PCI and MMIO virtio devices

## Security Model

kvmtool provides basic isolation:
1. **Host Firejail:** Sandboxes the lkvm process itself
2. **KVM isolation:** Hardware-enforced VM boundary
3. **Standard device model:** Full PCI support means larger attack surface

The combination of host Firejail + kvmtool provides good isolation through the VM boundary, but kvmtool itself has less security hardening than Firecracker or crosvm.

## Comparison

- **vs Firecracker:** kvmtool boots 38% faster but uses 34% more memory
- **vs crosvm:** kvmtool boots 43% faster but uses 17% more memory
- **vs Firejail-only:** Adds VM isolation layer with fastest boot time

## Verdict

kvmtool is the right choice when boot speed and simplicity are paramount, and you're willing to accept higher memory usage and less production hardening. It's excellent for development, testing, and rapid iteration where you need VMs to boot quickly. For production deployments with strict security requirements, Firecracker or crosvm would be better choices.

The speed advantage makes kvmtool ideal for:
- CI/CD pipelines that need fast VM boot times
- Development workflows with frequent VM restarts
- Benchmarking and performance testing
- Learning and experimentation with KVM
