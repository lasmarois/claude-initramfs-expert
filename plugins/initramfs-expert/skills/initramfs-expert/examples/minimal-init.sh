#!/bin/busybox sh
#
# Minimal initramfs /init script
# 
# This is the absolute minimum required to boot a systemd-based system.
# Use as a starting point for understanding the boot sequence.
#
# Requirements:
#   - Statically compiled busybox at /bin/busybox
#   - /dev/console and /dev/null device nodes
#   - Kernel with devtmpfs support
#
# Usage:
#   1. Copy this to initramfs root as 'init'
#   2. chmod +x init
#   3. Build: find . | cpio -o -H newc | gzip > initramfs.img
#

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Emergency shell fallback
rescue_shell() {
    echo "Boot Error: $*"
    echo "Starting emergency shell..."
    exec /bin/sh
}

# Mount virtual filesystems
mount -t devtmpfs devtmpfs /dev || rescue_shell "mount /dev"
mount -t proc proc /proc       || rescue_shell "mount /proc"
mount -t sysfs sysfs /sys      || rescue_shell "mount /sys"
mount -t tmpfs -o mode=0755 tmpfs /run

# Parse root= from kernel command line
root=""
for x in $(cat /proc/cmdline); do
    case "$x" in
        root=*) root="${x#root=}" ;;
    esac
done

[ -z "$root" ] && rescue_shell "No root= specified"

# Resolve UUID/LABEL
case "$root" in
    UUID=*|LABEL=*) root=$(findfs "$root") ;;
esac

# Wait for root device (simple timeout)
count=0
while [ ! -b "$root" ] && [ $count -lt 30 ]; do
    sleep 1
    count=$((count + 1))
done
[ -b "$root" ] || rescue_shell "Root device not found: $root"

# Mount root
mkdir -p /mnt/root
mount -o ro "$root" /mnt/root || rescue_shell "Mount root failed"

# Move virtual filesystems
mount --move /dev /mnt/root/dev
mount --move /proc /mnt/root/proc
mount --move /sys /mnt/root/sys
mount --move /run /mnt/root/run

# Switch to real root - MUST use exec
exec switch_root /mnt/root /sbin/init

# Should never reach here
rescue_shell "switch_root failed"
