# Squashfs Root with Overlayfs Reference

This document covers mounting squashfs as root filesystem with overlayfs for writability—the foundation of live systems, diskless workstations, and appliance deployments.

## Overview

Squashfs provides a compressed, read-only filesystem ideal for:
- **Diskless workstations**: Boot from network, run entirely in RAM
- **Kiosk systems**: Guaranteed clean state on each boot
- **Appliances**: Immutable base with controlled update path
- **Live USB/CD**: Portable, bootable systems

Overlayfs merges the read-only squashfs with a writable layer (tmpfs or persistent storage), providing transparent read-write access while preserving the base image.

## Kernel Requirements

Both modules must be enabled (standard in Ubuntu kernels):

```bash
# Check availability
modprobe squashfs && echo "squashfs OK"
modprobe overlay && echo "overlay OK"

# Or check config
grep -E "CONFIG_(SQUASHFS|OVERLAY_FS)" /boot/config-$(uname -r)
# CONFIG_SQUASHFS=y (or m)
# CONFIG_OVERLAY_FS=y (or m)
```

Required modules for initramfs:
```
squashfs        # Squashfs filesystem
overlay         # Overlayfs
loop            # Loop device (mount files as block devices)
```

## Creating Squashfs Images

### Basic Creation

```bash
# From directory
mksquashfs /path/to/rootfs rootfs.squashfs

# With compression (zstd recommended for speed/ratio balance)
mksquashfs /path/to/rootfs rootfs.squashfs -comp zstd -Xcompression-level 19

# Exclude paths
mksquashfs / rootfs.squashfs \
    -e /proc -e /sys -e /dev -e /run -e /tmp \
    -e /var/cache -e /var/tmp -e /var/log \
    -e /home/*/.cache

# From running system (careful with exclusions)
mksquashfs / /tmp/rootfs.squashfs \
    -comp zstd \
    -e /proc -e /sys -e /dev -e /run -e /tmp \
    -e /boot -e /swap -e /home \
    -e "*.log" -e "*.tmp" -e ".cache"
```

### Compression Options

| Algorithm | Ratio | Speed | Memory | Best For |
|-----------|-------|-------|--------|----------|
| gzip | Good | Fast | Low | Compatibility |
| lz4 | Fair | Fastest | Low | Boot speed priority |
| xz | Best | Slow | High | Size priority |
| zstd | Very Good | Fast | Medium | **Recommended balance** |
| lzo | Fair | Fast | Low | Legacy systems |

```bash
# zstd with maximum compression (slow create, fast decompress)
mksquashfs source dest.squashfs -comp zstd -Xcompression-level 22

# zstd balanced (faster create)
mksquashfs source dest.squashfs -comp zstd -Xcompression-level 15

# lz4 for fastest boot
mksquashfs source dest.squashfs -comp lz4 -Xhc
```

### Block Size Tuning

```bash
# Larger blocks = better compression, more RAM for decompression
mksquashfs source dest.squashfs -b 1M    # 1MB blocks (default 128K)

# Smaller blocks = faster random access, less RAM
mksquashfs source dest.squashfs -b 64K
```

## Overlayfs Architecture

### Layer Structure

```
┌─────────────────────────────┐
│        Merged View          │  ← Applications see this
│      /mnt/merged            │
├─────────────────────────────┤
│     Upper Layer (RW)        │  ← Writes go here
│   /mnt/rw/upper             │     (tmpfs or persistent)
├─────────────────────────────┤
│     Lower Layer (RO)        │  ← Read-only base
│   /mnt/ro (squashfs)        │     (squashfs image)
└─────────────────────────────┘
```

### Mount Requirements

```bash
# 1. Lower layer: read-only squashfs
mount -t squashfs -o ro,loop /path/to/image.squashfs /mnt/ro

# 2. Upper layer: writable filesystem
#    Option A: tmpfs (volatile - changes lost on reboot)
mount -t tmpfs -o size=2G,mode=755 tmpfs /mnt/rw
mkdir -p /mnt/rw/upper /mnt/rw/work

#    Option B: persistent partition
mount /dev/sda2 /mnt/rw
mkdir -p /mnt/rw/upper /mnt/rw/work

# 3. Overlay mount
mount -t overlay overlay \
    -o lowerdir=/mnt/ro,upperdir=/mnt/rw/upper,workdir=/mnt/rw/work \
    /mnt/merged
```

### Critical Requirements

1. **workdir must be on same filesystem as upperdir**
   ```bash
   # WRONG - different filesystems
   mount -t tmpfs tmpfs /mnt/upper
   mount -t tmpfs tmpfs /mnt/work
   mount -t overlay overlay -o lowerdir=...,upperdir=/mnt/upper,workdir=/mnt/work ...
   # Error: workdir and upperdir must reside on the same filesystem
   
   # CORRECT - same filesystem
   mount -t tmpfs tmpfs /mnt/rw
   mkdir /mnt/rw/upper /mnt/rw/work
   mount -t overlay overlay -o lowerdir=...,upperdir=/mnt/rw/upper,workdir=/mnt/rw/work ...
   ```

2. **workdir must be empty**
   ```bash
   # Clear workdir if reusing
   rm -rf /mnt/rw/work/*
   ```

3. **workdir must not be a subdirectory of upperdir (or vice versa)**

### Multiple Lower Layers

Overlayfs supports stacking multiple read-only layers:

```bash
# Rightmost is bottom layer
mount -t overlay overlay \
    -o lowerdir=/layer3:/layer2:/layer1,upperdir=/upper,workdir=/work \
    /merged

# Use case: base system + applications + customizations
mount -t overlay overlay \
    -o lowerdir=/mnt/custom:/mnt/apps:/mnt/base,upperdir=/mnt/rw/upper,workdir=/mnt/rw/work \
    /mnt/merged
```

## Complete Init Script Pattern

### Squashfs Root with tmpfs Overlay

```bash
#!/bin/busybox sh
#
# Boot squashfs root with tmpfs overlay (volatile)
#

PATH=/bin:/sbin
export PATH

rescue_shell() {
    echo "ERROR: $1"
    echo "Dropping to shell. Type 'exit' to retry."
    exec /bin/sh
}

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /run && mount -t tmpfs tmpfs /run

# Install busybox applets
/bin/busybox --install -s /bin

# Load required modules
modprobe loop
modprobe squashfs
modprobe overlay

# Parse kernel command line
SQUASHFS=""
OVERLAY_SIZE="2G"
for param in $(cat /proc/cmdline); do
    case "$param" in
        squashfs=*)    SQUASHFS="${param#squashfs=}" ;;
        overlay_size=*) OVERLAY_SIZE="${param#overlay_size=}" ;;
    esac
done

[ -z "$SQUASHFS" ] && rescue_shell "No squashfs= parameter"

# Wait for squashfs device/file
if [ -b "$SQUASHFS" ]; then
    # Block device containing squashfs
    SQFS_SOURCE="$SQUASHFS"
elif [ -f "$SQUASHFS" ]; then
    # File path
    SQFS_SOURCE="$SQUASHFS"
else
    # Try to resolve UUID/LABEL
    case "$SQUASHFS" in
        UUID=*|LABEL=*)
            SQFS_SOURCE=$(findfs "$SQUASHFS") || rescue_shell "Cannot find $SQUASHFS"
            ;;
        *)
            rescue_shell "Squashfs not found: $SQUASHFS"
            ;;
    esac
fi

# Create mount points
mkdir -p /mnt/ro /mnt/rw /mnt/merged

# Mount squashfs (read-only)
echo "Mounting squashfs from $SQFS_SOURCE..."
mount -t squashfs -o ro,loop "$SQFS_SOURCE" /mnt/ro || \
    rescue_shell "Failed to mount squashfs"

# Create tmpfs for writable layer
echo "Creating tmpfs overlay (size=$OVERLAY_SIZE)..."
mount -t tmpfs -o size=$OVERLAY_SIZE,mode=755 tmpfs /mnt/rw
mkdir -p /mnt/rw/upper /mnt/rw/work

# Mount overlay
echo "Mounting overlay filesystem..."
mount -t overlay overlay \
    -o lowerdir=/mnt/ro,upperdir=/mnt/rw/upper,workdir=/mnt/rw/work \
    /mnt/merged || rescue_shell "Failed to mount overlay"

# Move mounts to new root for persistence
mkdir -p /mnt/merged/mnt/ro /mnt/merged/mnt/rw
mount --move /mnt/ro /mnt/merged/mnt/ro
mount --move /mnt/rw /mnt/merged/mnt/rw

# Move virtual filesystems
mount --move /proc /mnt/merged/proc
mount --move /sys /mnt/merged/sys
mount --move /dev /mnt/merged/dev
mount --move /run /mnt/merged/run

# Switch to new root
echo "Switching to merged root..."
exec switch_root /mnt/merged /sbin/init

rescue_shell "switch_root failed"
```

### Kernel Command Line Examples

```bash
# Local squashfs file on ext4 partition
root=/dev/sda1 squashfs=/rootfs.squashfs

# Squashfs by UUID
squashfs=UUID=xxxx-xxxx

# With custom overlay size
squashfs=/rootfs.squashfs overlay_size=4G

# Load squashfs to RAM first (see toram section)
squashfs=/rootfs.squashfs toram
```

## Persistent Overlay

For systems needing persistence across reboots:

### Partition-Based Persistence

```bash
# Instead of tmpfs, use a partition
# Label the partition for easy identification
mkfs.ext4 -L persistence /dev/sda2

# In init script:
PERSIST_DEV=$(findfs LABEL=persistence)
mount "$PERSIST_DEV" /mnt/rw
mkdir -p /mnt/rw/upper /mnt/rw/work
```

### File-Based Persistence (Casper-style)

```bash
# Create persistence file on separate partition
dd if=/dev/zero of=/mnt/storage/persistence.img bs=1M count=4096
mkfs.ext4 -L casper-rw /mnt/storage/persistence.img

# In init script:
mount -o loop /mnt/storage/persistence.img /mnt/rw
```

### Selective Persistence

Persist only specific directories while keeping others volatile:

```bash
# Mount base overlay with tmpfs
mount -t overlay overlay \
    -o lowerdir=/mnt/ro,upperdir=/mnt/tmpfs/upper,workdir=/mnt/tmpfs/work \
    /mnt/merged

# Bind-mount persistent directories
mount /dev/sda2 /mnt/persist
mount --bind /mnt/persist/home /mnt/merged/home
mount --bind /mnt/persist/var/lib /mnt/merged/var/lib
```

## Copy-to-RAM (toram) Pattern

Loading squashfs entirely to RAM eliminates storage I/O and allows unmounting boot media:

```bash
#!/bin/busybox sh
# toram implementation

TORAM=0
for param in $(cat /proc/cmdline); do
    case "$param" in
        toram) TORAM=1 ;;
    esac
done

if [ "$TORAM" = "1" ]; then
    # Create RAM-based tmpfs for squashfs
    SQFS_SIZE=$(stat -c %s "$SQFS_SOURCE")
    SQFS_SIZE_MB=$((SQFS_SIZE / 1024 / 1024 + 100))  # Add 100MB buffer
    
    mount -t tmpfs -o size=${SQFS_SIZE_MB}M tmpfs /mnt/toram
    
    echo "Copying squashfs to RAM (${SQFS_SIZE_MB}MB)..."
    cp "$SQFS_SOURCE" /mnt/toram/rootfs.squashfs
    
    # Update source to RAM copy
    SQFS_SOURCE="/mnt/toram/rootfs.squashfs"
    
    # Can now unmount original media if desired
fi

# Continue with normal mount
mount -t squashfs -o ro,loop "$SQFS_SOURCE" /mnt/ro
```

### Memory Requirements

```
Minimum RAM = squashfs_size + overlay_size + system_overhead
```

| Squashfs | Overlay | System | Total Minimum |
|----------|---------|--------|---------------|
| 1 GB | 1 GB | 1 GB | 3 GB |
| 2 GB | 2 GB | 1 GB | 5 GB |
| 4 GB | 4 GB | 2 GB | 10 GB |

For desktop use with applications, recommend:
- **8 GB RAM** for 2 GB squashfs
- **16 GB RAM** for 4 GB squashfs

## Ubuntu Casper Reference

Casper is Ubuntu's live boot system, providing a reference implementation.

### Casper Boot Parameters

```bash
boot=casper                 # Enable Casper
toram                       # Copy squashfs to RAM
persistent                  # Enable persistence
persistent-path=/path      # Custom persistence location
nopersistent               # Disable persistence
union=overlay              # Use overlayfs (default)
```

### Casper Filesystem Layout

```
/casper/
├── filesystem.squashfs    # Main root filesystem
├── filesystem.manifest    # Package list
├── filesystem.size        # Size info
└── initrd                 # Casper initramfs
```

### Casper Persistence

```bash
# Create persistence partition
mkfs.ext4 -L casper-rw /dev/sda3

# Or persistence file
dd if=/dev/zero of=casper-rw bs=1M count=4096
mkfs.ext4 -F casper-rw
```

Casper searches for:
1. Partition labeled `casper-rw`
2. File named `casper-rw` on any partition
3. Directory `persistence.conf` specifying paths

## Updating Squashfs Images

### Full Replacement

```bash
# Generate new image from running system
mksquashfs / /tmp/new-rootfs.squashfs \
    -comp zstd \
    -e /proc -e /sys -e /dev -e /run -e /tmp \
    -e /mnt -e /media \
    -e "*.log"

# Replace on boot server/media
mv /tmp/new-rootfs.squashfs /srv/netboot/rootfs.squashfs
```

### Layered Updates

Instead of replacing entire image, add update layer:

```bash
# Create update squashfs with only changed files
mksquashfs /updates update-2024-01.squashfs -comp zstd

# Boot with stacked layers
# lowerdir=update-2024-01.squashfs:base-rootfs.squashfs
```

### A/B Update Pattern

```
/images/
├── rootfs-a.squashfs      # Current
├── rootfs-b.squashfs      # Updated
└── current -> rootfs-a.squashfs

# Update process:
1. Download new image to inactive slot (rootfs-b)
2. Verify checksum
3. Update symlink: current -> rootfs-b
4. Reboot
5. On failure, revert: current -> rootfs-a
```

## Troubleshooting

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `mount: unknown filesystem type 'squashfs'` | Module not loaded | `modprobe squashfs` |
| `mount: wrong fs type, bad option` on overlay | workdir issue | Ensure workdir on same fs as upperdir |
| `overlay: workdir is in-use` | Stale workdir | `rm -rf /path/to/work/*` |
| `loop: module not found` | Loop not loaded | `modprobe loop` |
| `no space left on device` | tmpfs full | Increase `size=` option |
| Slow performance | Swap thrashing | Increase RAM or reduce overlay size |

### Debugging Commands

```bash
# Check mounted overlays
mount | grep overlay
cat /proc/mounts | grep overlay

# Check overlay options
grep overlay /proc/mounts

# Check tmpfs usage
df -h | grep tmpfs

# Verify squashfs integrity
unsquashfs -s /path/to/image.squashfs

# List squashfs contents without extracting
unsquashfs -l /path/to/image.squashfs | head -100
```

### Performance Tuning

```bash
# Increase read-ahead for squashfs
echo 2048 > /sys/block/loop0/queue/read_ahead_kb

# Use deadline scheduler for loop device
echo deadline > /sys/block/loop0/queue/scheduler

# For tmpfs overlay, disable atime
mount -t tmpfs -o size=2G,noatime tmpfs /mnt/rw
```

## References

- Kernel overlayfs documentation: https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
- Squashfs documentation: https://www.kernel.org/doc/html/latest/filesystems/squashfs.html
- Ubuntu Casper: https://manpages.ubuntu.com/manpages/noble/man7/casper.7.html
- mksquashfs manpage: https://manpages.ubuntu.com/manpages/noble/man1/mksquashfs.1.html
