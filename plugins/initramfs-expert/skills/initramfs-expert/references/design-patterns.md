# initramfs Design Patterns Reference

This document contains production-ready patterns for custom initramfs implementations, derived from studying dracut, mkinitcpio, initramfs-tools, and embedded Linux approaches.

## Directory Structure Pattern

### Minimal Structure

```
initramfs/
├── bin/
│   └── busybox           # Statically linked, all applets
├── dev/
│   ├── console           # c 5 1 - required before devtmpfs
│   └── null              # c 1 3 - required before devtmpfs
├── etc/
├── lib/ → lib64/         # Symlink on x86_64
├── lib64/                 # For any required libraries
├── mnt/
│   └── root/             # Mount point for real root
├── proc/
├── run/                  # Critical for systemd handoff
├── sbin/ → bin/          # Optional symlink
├── sys/
└── init                  # The init script (must be executable)
```

### Production Structure

```
initramfs/
├── bin/
│   └── busybox
├── dev/
│   ├── console
│   └── null
├── etc/
│   ├── fstab             # Optional, for complex mounts
│   └── modprobe.d/       # Module options
├── lib/
│   ├── firmware/         # Required firmware blobs
│   └── modules/          # Kernel modules if needed
├── lib64/
├── mnt/
│   └── root/
├── proc/
├── run/
├── sbin/
│   ├── cryptsetup        # If LUKS support needed
│   ├── lvm               # If LVM support needed
│   └── modprobe → busybox
├── sys/
├── usr/
│   ├── bin/
│   └── sbin/
├── hooks/                # Modular hook scripts
│   ├── 01-early.sh
│   ├── 10-devices.sh
│   ├── 20-crypto.sh
│   ├── 30-lvm.sh
│   └── 90-mount.sh
└── init
```

## /init Script Patterns

### Minimal Production Init

```bash
#!/bin/busybox sh
#
# Minimal production initramfs init script
# Target: systemd-based distributions (Rocky Linux, RHEL, Fedora)
#

# Strict error handling
set -e

# Essential PATH
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

#######################################
# Emergency shell - ALWAYS include
#######################################
rescue_shell() {
    echo ""
    echo "================================================"
    echo "INITRAMFS ERROR: $*"
    echo "================================================"
    echo ""
    echo "Dropping to emergency shell."
    echo "Type 'exit' to attempt to continue boot."
    echo ""
    
    # Ensure we have a usable shell
    exec /bin/sh
}

#######################################
# Logging helper
#######################################
log() {
    echo "[initramfs] $*"
}

#######################################
# Mount essential virtual filesystems
#######################################
mount_virtfs() {
    log "Mounting virtual filesystems..."
    
    # devtmpfs first - provides device nodes
    mount -t devtmpfs devtmpfs /dev || rescue_shell "Failed to mount /dev"
    
    # Create essential directories in /dev
    mkdir -p /dev/pts /dev/shm
    
    # procfs - needed for /proc/cmdline
    mount -t proc proc /proc || rescue_shell "Failed to mount /proc"
    
    # sysfs - needed for device discovery
    mount -t sysfs sysfs /sys || rescue_shell "Failed to mount /sys"
    
    # tmpfs on /run - CRITICAL for systemd
    mount -t tmpfs -o mode=0755,nodev,nosuid,strictatime tmpfs /run || \
        rescue_shell "Failed to mount /run"
}

#######################################
# Parse kernel command line
#######################################
parse_cmdline() {
    log "Parsing kernel command line..."
    
    # Defaults
    root=""
    rootfstype="auto"
    rootflags=""
    init="/sbin/init"
    ro="ro"
    
    for param in $(cat /proc/cmdline); do
        case "$param" in
            root=*)
                root="${param#root=}"
                ;;
            rootfstype=*)
                rootfstype="${param#rootfstype=}"
                ;;
            rootflags=*)
                rootflags="${param#rootflags=}"
                ;;
            init=*)
                init="${param#init=}"
                ;;
            ro)
                ro="ro"
                ;;
            rw)
                ro="rw"
                ;;
            rd.shell|rd.break)
                log "Break requested, dropping to shell"
                rescue_shell "Break requested via kernel command line"
                ;;
        esac
    done
    
    [ -z "$root" ] && rescue_shell "No root= parameter specified"
}

#######################################
# Resolve device specification
#######################################
resolve_device() {
    local spec="$1"
    
    case "$spec" in
        UUID=*)
            findfs "$spec" 2>/dev/null || echo ""
            ;;
        LABEL=*)
            findfs "$spec" 2>/dev/null || echo ""
            ;;
        /dev/*)
            echo "$spec"
            ;;
        *)
            echo "/dev/$spec"
            ;;
    esac
}

#######################################
# Wait for device to appear
#######################################
wait_for_device() {
    local device="$1"
    local timeout="${2:-30}"
    local count=0
    
    log "Waiting for device: $device (timeout: ${timeout}s)"
    
    while [ ! -b "$device" ] && [ $count -lt $timeout ]; do
        sleep 1
        count=$((count + 1))
        
        # Re-resolve in case it's UUID/LABEL
        if [ $((count % 5)) -eq 0 ]; then
            device=$(resolve_device "$root")
        fi
    done
    
    if [ ! -b "$device" ]; then
        log "Available block devices:"
        ls -la /dev/[hsv]d* /dev/nvme* /dev/mmcblk* 2>/dev/null || true
        rescue_shell "Device $device not found after ${timeout}s"
    fi
    
    echo "$device"
}

#######################################
# Mount root filesystem
#######################################
mount_root() {
    local device="$1"
    local mountopts="$ro"
    
    [ -n "$rootflags" ] && mountopts="${mountopts},${rootflags}"
    
    log "Mounting root filesystem: $device -> /mnt/root"
    log "  Type: $rootfstype, Options: $mountopts"
    
    mount -t "$rootfstype" -o "$mountopts" "$device" /mnt/root || \
        rescue_shell "Failed to mount root filesystem"
}

#######################################
# Handoff to real init
#######################################
switch_to_real_root() {
    log "Preparing to switch to real root..."
    
    # Verify real init exists
    if [ ! -x "/mnt/root${init}" ]; then
        log "Warning: $init not found, trying alternatives..."
        for alt_init in /usr/lib/systemd/systemd /lib/systemd/systemd /sbin/init; do
            if [ -x "/mnt/root${alt_init}" ]; then
                init="$alt_init"
                log "Using alternative init: $init"
                break
            fi
        done
    fi
    
    [ ! -x "/mnt/root${init}" ] && rescue_shell "No valid init found on real root"
    
    # Move virtual filesystems to new root
    log "Moving virtual filesystems..."
    mount --move /dev /mnt/root/dev || rescue_shell "Failed to move /dev"
    mount --move /proc /mnt/root/proc || rescue_shell "Failed to move /proc"
    mount --move /sys /mnt/root/sys || rescue_shell "Failed to move /sys"
    mount --move /run /mnt/root/run || rescue_shell "Failed to move /run"
    
    log "Executing switch_root to $init"
    
    # switch_root: delete initramfs contents, chroot, exec new init
    # This MUST be called from PID 1 - exec ensures we maintain PID 1
    exec switch_root /mnt/root "$init"
    
    # If we reach here, something went terribly wrong
    rescue_shell "switch_root failed!"
}

#######################################
# Main
#######################################
main() {
    log "Custom initramfs starting..."
    log "Kernel: $(uname -r)"
    
    mount_virtfs
    parse_cmdline
    
    # Resolve and wait for root device
    device=$(resolve_device "$root")
    device=$(wait_for_device "$device")
    
    mount_root "$device"
    switch_to_real_root
}

# Execute main function
main
```

### Modular Hook System

For larger implementations, use a hook-based architecture:

```bash
#!/bin/busybox sh
# init - main entry point with hook system

run_hooks() {
    local stage="$1"
    local hookdir="/hooks/${stage}.d"
    
    if [ -d "$hookdir" ]; then
        for hook in "$hookdir"/*; do
            [ -x "$hook" ] && . "$hook"
        done
    fi
}

# ... setup code ...

run_hooks "pre-mount"
# mount root
run_hooks "post-mount"
# switch_root
```

## busybox Configuration

### Essential Applets

These busybox applets are required for a functional initramfs:

**Core utilities:**
- `sh` - Shell interpreter
- `echo`, `cat`, `ls`, `mkdir`, `rm`, `cp`, `mv`
- `mount`, `umount`
- `switch_root`

**Device handling:**
- `mdev` - Device manager (if not using devtmpfs alone)
- `mknod`
- `blkid`, `findfs` - Device identification

**Debugging:**
- `dmesg`
- `sleep`
- `true`, `false`

**Optional but recommended:**
- `modprobe`, `insmod` - Module loading
- `grep`, `sed`, `awk` - Text processing
- `cryptsetup` - LUKS support (separate binary)
- `lvm` - LVM support (separate binary)

### Static Compilation

Always compile busybox statically for initramfs:

```bash
make menuconfig
# Enable: Settings -> Build static binary (no shared libs)
make -j$(nproc)
make CONFIG_PREFIX=/path/to/initramfs install
```

## Error Handling Patterns

### Defensive Scripting

```bash
# Always quote variables
mount -t "$fstype" "$device" "$mountpoint"

# Check command success
if ! mount -t ext4 /dev/sda1 /mnt/root; then
    rescue_shell "Mount failed"
fi

# Use set -e cautiously (can cause silent failures)
# Better: explicit error checks

# Timeout patterns
wait_with_timeout() {
    local condition="$1"
    local timeout="$2"
    local interval="${3:-1}"
    local elapsed=0
    
    while ! eval "$condition"; do
        sleep "$interval"
        elapsed=$((elapsed + interval))
        [ $elapsed -ge $timeout ] && return 1
    done
    return 0
}
```

### Debug Mode

```bash
# Check for debug flag
if grep -q "rd.debug" /proc/cmdline; then
    set -x  # Enable command tracing
    exec 2>/run/initramfs.log  # Log to file
fi
```

## Distribution Patterns Reference

### dracut (Red Hat/Fedora)

Key patterns to learn from:
- Numeric prefixes for module ordering (00-99)
- Hook stages: cmdline, pre-udev, pre-trigger, initqueue, pre-mount, mount, pre-pivot, cleanup
- `check()`, `depends()`, `install()`, `installkernel()` functions
- Earlier modules override later ones (won't overwrite existing files)

### mkinitcpio (Arch)

Key patterns:
- Separation of build hooks and runtime hooks
- `run_earlyhook()`, `run_hook()`, `run_latehook()`, `run_cleanuphook()`
- HOOKS array for ordering
- `autodetect` hook for minimal images

### initramfs-tools (Debian)

Key patterns:
- Stage directories: init-top, init-premount, local-top, local-block, local-premount, local-bottom, init-bottom
- PREREQ variable for dependencies
- Separate build-time and boot-time hooks
