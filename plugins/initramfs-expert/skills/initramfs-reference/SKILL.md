---
name: initramfs-reference
description: "Reference documentation for the initramfs-architect agent. Contains kernel boot contracts, design patterns, systemd handoff requirements, and advanced feature guides. NOT for direct use - always use the initramfs-architect agent instead."
---

# initramfs Reference

> **Note:** This skill is a reference library for the `initramfs-architect` agent. Do not invoke directly - use the agent for initramfs tasks.

This skill provides comprehensive reference documentation for building custom Linux initramfs implementations from first principles, targeting systemd-based distributions like Rocky Linux and RHEL.

## Contents

This skill contains reference material for:
- Kernel initramfs contract and cpio format
- busybox-based /init script patterns
- switch_root and systemd handoff requirements
- LUKS encryption and LVM integration
- Device discovery strategies
- Debugging techniques

## Quick Reference

### The Kernel's Contract

The kernel expects:
1. **newc format cpio archive** (magic number `070701`)
2. **`/init` as PID 1** - must be executable, must never return
3. **`switch_root` for transition** - not `pivot_root` (rootfs cannot be unmounted)

### Critical Mounting Order

```bash
mount -t devtmpfs devtmpfs /dev   # First - provides device nodes
mount -t proc proc /proc          # Second - enables /proc/cmdline
mount -t sysfs sysfs /sys         # Third - required for device discovery
mount -t tmpfs -o mode=0755,nodev,nosuid,strictatime tmpfs /run  # Critical for systemd
```

### switch_root Requirements

- Must run as PID 1 (no subprocess)
- Deletes all initramfs contents
- Moves /dev, /proc, /sys, /run to new root
- chroots and exec's new init
- Failure = kernel panic ("attempted to kill init")

### systemd Handoff Checklist

- [ ] `/run` mounted as tmpfs with correct options
- [ ] Virtual filesystems will be moved (not unmounted)
- [ ] Real root mounted (convention: `/sysroot` or `/mnt/root`)
- [ ] exec to `/usr/lib/systemd/systemd` or `/sbin/init`

## Reference Documentation

For detailed information, consult these reference files in this skill:

- **`references/kernel-documentation.md`** - Kernel initramfs contract, cpio format, boot parameters
- **`references/design-patterns.md`** - Production init script patterns, modular architecture, error handling
- **`references/systemd-handoff.md`** - systemd interface requirements, /run preservation, clean transitions
- **`references/advanced-features.md`** - LUKS integration, LVM activation, network boot, microcode loading

## Example Scripts

- **`examples/minimal-init.sh`** - Bare minimum working /init for reference
- **`scripts/validate-initramfs.sh`** - Validate cpio archive structure

## Essential Commands

### Build initramfs
```bash
cd /path/to/initramfs
find . | cpio -o -H newc | gzip > /boot/initramfs.img
```

### Extract for inspection
```bash
mkdir /tmp/initramfs && cd /tmp/initramfs
zcat /boot/initramfs.img | cpio -idmv
```

### Test with QEMU
```bash
qemu-system-x86_64 -kernel /boot/vmlinuz \
  -initrd /boot/initramfs.img \
  -append "root=/dev/sda1 console=ttyS0 rd.shell=1" \
  -nographic -hda disk.img
```

## Common Pitfalls

1. **Using `-depth` with find** - Breaks extraction (directories must precede contents)
2. **Calling switch_root from subprocess** - Kernel panic
3. **Forgetting /run for systemd** - Boot hangs or fails
4. **Missing initial device nodes** - /dev/console and /dev/null needed before devtmpfs
5. **Absolute paths in cpio** - Use relative paths from initramfs root

## Authoritative Sources

- Kernel docs: `Documentation/filesystems/ramfs-rootfs-initramfs.rst`
- systemd interface: `https://systemd.io/INITRD_INTERFACE/`
- dracut architecture: Reference for hook/module patterns
- LFS initramfs: Educational minimal implementation
