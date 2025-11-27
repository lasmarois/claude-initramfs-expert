# Kernel initramfs Documentation Reference

This document contains authoritative information about the Linux kernel's initramfs contract, derived from official kernel documentation.

## Primary Sources

| Document | URL |
|----------|-----|
| ramfs-rootfs-initramfs | https://www.kernel.org/doc/html/latest/filesystems/ramfs-rootfs-initramfs.html |
| Early userspace support | https://docs.kernel.org/driver-api/early-userspace/early_userspace_support.html |
| initramfs buffer format | https://docs.kernel.org/driver-api/early-userspace/buffer-format.html |
| Microcode loading | https://docs.kernel.org/arch/x86/microcode.html |

## The Kernel's initramfs Contract

### What the Kernel Does

1. Extracts the cpio archive to rootfs (a special ramfs instance)
2. Executes `/init` as PID 1 with root privileges
3. Passes control entirely to userspace

### What /init Must Do

1. **Never return** - The kernel expects /init to handle everything and exec the final init
2. **Mount necessary filesystems** - proc, sys, dev at minimum
3. **Locate and mount root device** - Parse kernel command line, wait for devices
4. **Transfer control** - Use `switch_root` to hand off to real init

### Why switch_root, Not pivot_root

From the kernel documentation:

> "The initramfs is rootfs: you can neither pivot_root rootfs, nor unmount it."

Rob Landley created `switch_root` specifically because:
- rootfs is the root of the VFS and cannot be unmounted
- pivot_root requires unmounting the old root
- switch_root deletes everything from rootfs, moves the new root to /, and exec's the new init

## cpio Archive Format

### Required Format: newc

The kernel requires **newc format** cpio archives (SVR4 with no CRC):
- Magic number: `070701`
- ASCII headers with fixed-width fields
- Supports large files and device nodes

### Creating Valid Archives

```bash
# CORRECT - directories precede their contents
cd /path/to/initramfs
find . | cpio -o -H newc | gzip > initramfs.img

# WRONG - using -depth breaks extraction
find . -depth | cpio -o -H newc > initramfs.img  # DON'T DO THIS
```

**Critical Warning**: The `-depth` flag causes files to be listed before their parent directories. The kernel's cpio extractor cannot create files in directories that don't exist yet.

### Archive Concatenation

The kernel grammar permits multiple concatenated archives:

```
initramfs := ("\0" | cpio_archive | cpio_compressed_archive)*
```

This enables:
- Early microcode cpio (uncompressed) prepended to main initramfs
- Layered initramfs builds

### Compression Support

The kernel supports these compression formats for initramfs:
- gzip (most common)
- bzip2
- lzma
- xz
- lz4
- zstd (if kernel configured)

## Kernel Command Line Parameters

### Root Device Specification

| Parameter | Description | Example |
|-----------|-------------|---------|
| `root=` | Root device | `root=/dev/sda1`, `root=UUID=xxx`, `root=LABEL=xxx` |
| `rootfstype=` | Filesystem type | `rootfstype=ext4` |
| `rootflags=` | Mount options | `rootflags=data=journal` |
| `ro` | Mount read-only | (flag) |
| `rw` | Mount read-write | (flag) |
| `rootwait` | Wait indefinitely for root device | (flag) |
| `rootdelay=N` | Wait N seconds before mounting | `rootdelay=10` |

### init Specification

| Parameter | Description | Example |
|-----------|-------------|---------|
| `init=` | Path to init binary | `init=/sbin/init`, `init=/bin/sh` |
| `rdinit=` | Path to /init in initramfs | `rdinit=/init.custom` |

### Debugging Parameters

| Parameter | Description |
|-----------|-------------|
| `rd.shell` | Drop to shell after loading initramfs (dracut) |
| `rd.break=hookpoint` | Break at specific boot stage (dracut) |
| `rd.debug` | Enable verbose initramfs logging (dracut) |
| `debug` | Enable kernel debug messages |
| `earlyprintk` | Enable early console output |

## CPU Microcode Loading

For early microcode loading, the kernel expects:
- An **uncompressed** cpio archive prepended to the main initramfs
- Microcode at `kernel/x86/microcode/GenuineIntel.bin` or `AuthenticAMD.bin`

### Structure

```
early-microcode.cpio (uncompressed)
├── kernel/
│   └── x86/
│       └── microcode/
│           └── GenuineIntel.bin  # or AuthenticAMD.bin
```

### Building Combined Image

```bash
# Create early microcode cpio
mkdir -p kernel/x86/microcode
cp /lib/firmware/intel-ucode/* kernel/x86/microcode/GenuineIntel.bin
find kernel | cpio -o -H newc > /tmp/early.cpio

# Combine with main initramfs
cat /tmp/early.cpio /boot/initramfs.img.gz > /boot/initramfs-combined.img
```

## Device Nodes in Early Boot

### Minimal Required Nodes

Before devtmpfs is mounted, these nodes must exist:

```bash
mknod -m 640 /dev/console c 5 1   # For kernel console output
mknod -m 666 /dev/null c 1 3      # For discarding output
```

### devtmpfs

With `CONFIG_DEVTMPFS` enabled:
```bash
mount -t devtmpfs devtmpfs /dev
```

The kernel automatically populates `/dev` with device nodes for all registered devices.

### Dynamic Device Discovery

Options for handling device enumeration:
1. **devtmpfs only** - Kernel auto-populates, simplest approach
2. **mdev (busybox)** - Lightweight udev alternative for hotplug
3. **Manual nodes** - For known, static hardware configurations

## References for Further Reading

- LWN.net "Initramfs arrives" (2002): https://lwn.net/Articles/14776/
- LWN.net devtmpfs introduction: https://lwn.net/Articles/345480/
- Linux From Scratch initramfs: https://www.linuxfromscratch.org/blfs/view/svn/postlfs/initramfs.html
