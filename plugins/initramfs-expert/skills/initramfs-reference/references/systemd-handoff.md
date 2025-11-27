# systemd Handoff Reference

This document details the requirements for properly handing off from a custom shell-based initramfs to systemd on the real root filesystem.

## Official Documentation

Primary source: https://systemd.io/INITRD_INTERFACE/

## The systemd initrd Interface

### Key Distinction

There are two fundamentally different scenarios:
1. **systemd-based initramfs** (like dracut generates) - systemd runs as PID 1 inside initramfs
2. **Shell-based initramfs handing off to systemd** - shell script runs as PID 1, then execs systemd

For custom busybox/shell implementations, you're doing #2.

### Detection Mechanism

systemd determines if it's running inside an initramfs by checking for `/etc/initrd-release`.

**For shell-based initramfs handing to systemd:**
- Your initramfs should NOT have `/etc/initrd-release`
- When you switch_root to the real root, that file won't exist on the real system
- systemd starts in normal system mode, which is what you want

### /run Requirements

This is the most critical requirement for systemd handoff.

**/run MUST be:**
- Mounted as tmpfs
- With specific options: `mode=0755,nodev,nosuid,strictatime`
- Preserved across switch_root (not unmounted)

```bash
mount -t tmpfs -o mode=0755,nodev,nosuid,strictatime tmpfs /run
```

**Why this matters:**
- systemd expects /run to be available immediately
- Early boot services write state to /run
- Socket activation depends on /run/systemd/
- If /run isn't mounted or is mounted incorrectly, boot may hang

### Virtual Filesystem Handling

The switch_root command (from util-linux or busybox) automatically handles:
- Moving /proc, /dev, /sys, /run to the new root
- These are NOT unmounted

Explicit moves in your init script (before switch_root):
```bash
mount --move /dev /mnt/root/dev
mount --move /proc /mnt/root/proc
mount --move /sys /mnt/root/sys
mount --move /run /mnt/root/run
```

Or let switch_root handle it (check your switch_root implementation).

## Complete Handoff Sequence

### Step 1: Prepare Virtual Filesystems

```bash
# These must be mounted before anything else
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# Critical for systemd - exact options matter
mount -t tmpfs -o mode=0755,nodev,nosuid,strictatime tmpfs /run
```

### Step 2: Mount Real Root

```bash
# Parse root= from kernel command line
# Wait for device if necessary
# Mount to conventional location

mkdir -p /sysroot  # or /mnt/root
mount -t ext4 -o ro /dev/sda1 /sysroot
```

### Step 3: Verify systemd Exists

```bash
# Check for systemd on real root
INIT="/usr/lib/systemd/systemd"

if [ ! -x "/sysroot${INIT}" ]; then
    # Try alternatives
    for alt in /lib/systemd/systemd /sbin/init; do
        if [ -x "/sysroot${alt}" ]; then
            INIT="$alt"
            break
        fi
    done
fi
```

### Step 4: Move Virtual Filesystems

```bash
# Move, don't unmount
mount --move /dev /sysroot/dev
mount --move /proc /sysroot/proc
mount --move /sys /sysroot/sys
mount --move /run /sysroot/run
```

### Step 5: Execute switch_root

```bash
# MUST use exec to maintain PID 1
exec switch_root /sysroot "$INIT"
```

## systemd Boot Target

After handoff, systemd:
1. Starts as PID 1 on the real root
2. Runs generators to process /etc/fstab
3. Activates default.target (usually graphical.target or multi-user.target)
4. Mounts remaining filesystems
5. Starts services

## Optional: Emergency Root Preservation

For recovery scenarios, you can preserve part of the initramfs:

```bash
# Create directory for emergency tools
mkdir -p /run/initramfs

# Copy essential recovery tools
cp -a /bin/busybox /run/initramfs/
cp -a /sbin/cryptsetup /run/initramfs/ 2>/dev/null || true

# This survives switch_root because /run is moved
```

systemd's shutdown process can use `/run/initramfs` if present.

## Debugging Handoff Issues

### Symptoms and Causes

| Symptom | Likely Cause |
|---------|--------------|
| Boot hangs after switch_root | /run not mounted or wrong options |
| "Attempted to kill init" | switch_root called from subprocess, not PID 1 |
| systemd emergency mode | Root mounted wrong, missing essential services |
| No console output | /dev not moved properly, console device missing |

### Debug Approach

1. **Add rd.break equivalent:**
```bash
# In your init script
if grep -q "rd.break=pre-pivot" /proc/cmdline; then
    echo "Break before switch_root - type 'exit' to continue"
    /bin/sh
fi
```

2. **Verify mounts before switch:**
```bash
echo "=== Mount status before switch_root ==="
cat /proc/mounts
echo "=== /sysroot contents ==="
ls -la /sysroot/
ls -la /sysroot/sbin/ /sysroot/usr/lib/systemd/
```

3. **Check systemd directly:**
```bash
chroot /sysroot /bin/bash
systemctl --version
```

## systemd-specific Kernel Parameters

These parameters affect systemd behavior after handoff:

| Parameter | Effect |
|-----------|--------|
| `systemd.unit=` | Override default target (e.g., `rescue.target`) |
| `systemd.debug` | Enable systemd debug logging |
| `systemd.log_level=debug` | Verbose logging |
| `systemd.log_target=console` | Force console logging |
| `rd.systemd.*` | Initramfs-specific (only for systemd-based initramfs) |

## Rocky Linux / RHEL Specifics

### Default Init Location

On RHEL-family systems:
- Primary: `/usr/lib/systemd/systemd`
- Symlink: `/sbin/init` → `/usr/lib/systemd/systemd`

### SELinux Considerations

If SELinux is enabled:
1. The initramfs doesn't typically need SELinux support
2. systemd handles SELinux policy loading after handoff
3. Ensure the root filesystem is mounted with correct context

### Typical Rocky Linux Boot Flow

```
BIOS/UEFI → GRUB2 → vmlinuz + initramfs
                         ↓
            initramfs /init (your script)
                         ↓
            switch_root to real root
                         ↓
            /usr/lib/systemd/systemd as PID 1
                         ↓
            systemd-journald, systemd-udevd
                         ↓
            basic.target → multi-user.target
```
