#!/bin/busybox sh
#
# ubuntu-squashfs-nm-init.sh
#
# Complete init script for Ubuntu 22.04/24.04 LTS
# Boots squashfs root via network using NetworkManager
#
# Features:
#   - NetworkManager in initrd mode (no D-Bus required)
#   - Squashfs root with overlayfs (tmpfs or persistent)
#   - Optional copy-to-RAM (toram)
#   - HTTP/NFS squashfs fetch
#   - Clean systemd handoff
#
# Kernel parameters:
#   squashfs=<url|path>     - Squashfs location (required)
#   overlay_size=<size>     - Overlay tmpfs size (default: 2G)
#   toram                   - Copy squashfs to RAM
#   persistent=<dev>        - Device for persistent overlay
#   ip=dhcp | ip=<static>   - Network configuration
#   break=<stage>           - Debug breakpoint
#   debug                   - Enable verbose logging
#
# Examples:
#   squashfs=http://192.168.1.1/images/rootfs.squashfs ip=dhcp
#   squashfs=/dev/sda1:/rootfs.squashfs overlay_size=4G
#   squashfs=nfs:192.168.1.1:/srv/images/rootfs.squashfs ip=eth0:dhcp toram
#

set -e

#######################################
# Configuration
#######################################
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Defaults
OVERLAY_SIZE="2G"
NM_TIMEOUT="60"
ROOT_TIMEOUT="30"
DEBUG=0
TORAM=0

# Mount points
MNT_RO="/mnt/ro"
MNT_RW="/mnt/rw"
MNT_MERGED="/mnt/merged"
MNT_TORAM="/mnt/toram"

#######################################
# Utility Functions
#######################################

log() {
    echo "[initramfs] $*"
}

log_debug() {
    [ "$DEBUG" = "1" ] && echo "[DEBUG] $*"
}

rescue_shell() {
    echo ""
    echo "========================================"
    echo "INITRAMFS ERROR: $*"
    echo "========================================"
    echo ""
    echo "Useful commands:"
    echo "  ip addr              - Show network interfaces"
    echo "  cat /proc/cmdline    - Show kernel parameters"
    echo "  ls /dev              - List devices"
    echo "  dmesg | tail         - Recent kernel messages"
    echo ""
    echo "Type 'exit' to attempt to continue boot."
    echo ""
    exec /bin/sh
}

check_break() {
    local stage="$1"
    if echo "$BREAK_STAGES" | grep -qw "$stage"; then
        log "Break point: $stage"
        log "Type 'exit' to continue"
        /bin/sh
    fi
}

#######################################
# Parse Kernel Command Line
#######################################

parse_cmdline() {
    log "Parsing kernel command line..."
    
    SQUASHFS=""
    PERSISTENT=""
    IP_CONFIG=""
    BREAK_STAGES=""
    
    for param in $(cat /proc/cmdline); do
        case "$param" in
            squashfs=*)
                SQUASHFS="${param#squashfs=}"
                ;;
            overlay_size=*)
                OVERLAY_SIZE="${param#overlay_size=}"
                ;;
            persistent=*)
                PERSISTENT="${param#persistent=}"
                ;;
            toram)
                TORAM=1
                ;;
            ip=*)
                IP_CONFIG="${param#ip=}"
                ;;
            break=*)
                BREAK_STAGES="${param#break=}"
                ;;
            debug)
                DEBUG=1
                set -x
                ;;
            rd.debug)
                DEBUG=1
                set -x
                ;;
        esac
    done
    
    [ -z "$SQUASHFS" ] && rescue_shell "No squashfs= parameter specified"
    
    log_debug "SQUASHFS=$SQUASHFS"
    log_debug "OVERLAY_SIZE=$OVERLAY_SIZE"
    log_debug "TORAM=$TORAM"
    log_debug "IP_CONFIG=$IP_CONFIG"
}

#######################################
# Mount Essential Filesystems
#######################################

mount_essential() {
    log "Mounting essential filesystems..."
    
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    
    mkdir -p /dev/pts /dev/shm
    mount -t devpts devpts /dev/pts
    mount -t tmpfs tmpfs /dev/shm
    
    # /run with systemd-compatible options
    mkdir -p /run
    mount -t tmpfs -o mode=0755,nodev,nosuid,strictatime tmpfs /run
    mkdir -p /run/lock /run/NetworkManager/system-connections
    
    # Create /var/run symlink (needed by some tools)
    ln -sf /run /var/run
    
    # Install busybox applets
    /bin/busybox --install -s /bin
}

#######################################
# Load Kernel Modules
#######################################

load_modules() {
    log "Loading kernel modules..."
    
    # Network (af_packet required for NetworkManager)
    modprobe af_packet 2>/dev/null || true
    
    # Filesystems
    modprobe squashfs || rescue_shell "squashfs module not available"
    modprobe overlay || rescue_shell "overlay module not available"
    modprobe loop || rescue_shell "loop module not available"
    
    # Common network drivers (try several)
    for drv in e1000e igb ixgbe virtio_net; do
        modprobe "$drv" 2>/dev/null || true
    done
    
    # Storage (for local squashfs)
    for drv in ahci nvme sd_mod usb_storage; do
        modprobe "$drv" 2>/dev/null || true
    done
    
    # Allow devices to settle
    sleep 2
}

#######################################
# Configure Network with NetworkManager
#######################################

configure_network() {
    log "Configuring network with NetworkManager..."
    
    # Check for NetworkManager
    if [ ! -x /usr/sbin/NetworkManager ]; then
        log "NetworkManager not found, trying manual configuration..."
        configure_network_manual
        return
    fi
    
    # Generate connections from kernel command line if nm-initrd-generator exists
    if [ -x /usr/libexec/nm-initrd-generator ]; then
        log_debug "Generating NM profiles from kernel cmdline"
        /usr/libexec/nm-initrd-generator -- $(cat /proc/cmdline)
    fi
    
    # Start NetworkManager in initrd mode
    log "Starting NetworkManager (timeout: ${NM_TIMEOUT}s)..."
    /usr/sbin/NetworkManager --configure-and-quit=initrd &
    NM_PID=$!
    
    # Wait for network to come up
    if /usr/bin/nm-online -t "$NM_TIMEOUT" -s 2>/dev/null; then
        log "Network is online"
    else
        log "WARNING: nm-online timeout, checking manually..."
        # Check if we have any IP address
        if ip addr | grep -q "inet.*scope global"; then
            log "Network appears configured"
        else
            wait $NM_PID 2>/dev/null || true
            rescue_shell "Network configuration failed"
        fi
    fi
    
    # Wait for NM to exit
    wait $NM_PID 2>/dev/null || true
    
    # Show network status
    log_debug "Network interfaces:"
    [ "$DEBUG" = "1" ] && ip addr
}

configure_network_manual() {
    # Fallback: manual network configuration
    local iface=""
    
    # Find first ethernet interface
    for i in /sys/class/net/e*; do
        [ -d "$i" ] && iface=$(basename "$i") && break
    done
    
    [ -z "$iface" ] && rescue_shell "No network interface found"
    
    ip link set "$iface" up
    
    case "$IP_CONFIG" in
        dhcp|"")
            log "Configuring $iface via DHCP..."
            udhcpc -i "$iface" -t 10 -n || rescue_shell "DHCP failed on $iface"
            ;;
        *)
            # Parse static: ip=addr::gw:mask:host:iface:off
            local addr gw mask
            addr=$(echo "$IP_CONFIG" | cut -d: -f1)
            gw=$(echo "$IP_CONFIG" | cut -d: -f3)
            mask=$(echo "$IP_CONFIG" | cut -d: -f4)
            
            ip addr add "${addr}/${mask}" dev "$iface"
            [ -n "$gw" ] && ip route add default via "$gw"
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            ;;
    esac
}

#######################################
# Fetch Squashfs Image
#######################################

fetch_squashfs() {
    log "Fetching squashfs image..."
    
    local sqfs_path=""
    
    case "$SQUASHFS" in
        http://*|https://*)
            log "Downloading from $SQUASHFS..."
            sqfs_path="/tmp/rootfs.squashfs"
            
            if command -v wget >/dev/null; then
                wget -O "$sqfs_path" "$SQUASHFS" || rescue_shell "Download failed"
            elif command -v curl >/dev/null; then
                curl -o "$sqfs_path" "$SQUASHFS" || rescue_shell "Download failed"
            else
                rescue_shell "No wget or curl available"
            fi
            ;;
            
        nfs:*)
            # Format: nfs:server:/path/to/file.squashfs
            local nfs_spec="${SQUASHFS#nfs:}"
            local nfs_server="${nfs_spec%%:*}"
            local nfs_path="${nfs_spec#*:}"
            
            log "Mounting NFS from $nfs_server:$nfs_path..."
            mkdir -p /mnt/nfs
            mount -t nfs -o ro,nolock "$nfs_server:$(dirname $nfs_path)" /mnt/nfs || \
                rescue_shell "NFS mount failed"
            sqfs_path="/mnt/nfs/$(basename $nfs_path)"
            ;;
            
        /dev/*:*)
            # Format: /dev/sda1:/path/to/file.squashfs
            local dev="${SQUASHFS%%:*}"
            local path="${SQUASHFS#*:}"
            
            log "Mounting $dev to access $path..."
            
            # Wait for device
            local count=0
            while [ ! -b "$dev" ] && [ $count -lt $ROOT_TIMEOUT ]; do
                sleep 1
                count=$((count + 1))
            done
            [ -b "$dev" ] || rescue_shell "Device $dev not found"
            
            mkdir -p /mnt/boot
            mount -o ro "$dev" /mnt/boot || rescue_shell "Failed to mount $dev"
            sqfs_path="/mnt/boot${path}"
            ;;
            
        UUID=*|LABEL=*)
            log "Resolving $SQUASHFS..."
            local dev=$(findfs "$SQUASHFS") || rescue_shell "Cannot find $SQUASHFS"
            
            # Wait for device
            local count=0
            while [ ! -b "$dev" ] && [ $count -lt $ROOT_TIMEOUT ]; do
                sleep 1
                count=$((count + 1))
            done
            
            mkdir -p /mnt/boot
            mount -o ro "$dev" /mnt/boot || rescue_shell "Failed to mount $dev"
            sqfs_path="/mnt/boot/rootfs.squashfs"  # Assume standard name
            ;;
            
        *)
            # Direct path
            sqfs_path="$SQUASHFS"
            ;;
    esac
    
    [ -f "$sqfs_path" ] || rescue_shell "Squashfs not found: $sqfs_path"
    
    # Optional: copy to RAM
    if [ "$TORAM" = "1" ]; then
        log "Copying squashfs to RAM..."
        local sqfs_size=$(stat -c %s "$sqfs_path")
        local sqfs_size_mb=$((sqfs_size / 1024 / 1024 + 100))
        
        mkdir -p "$MNT_TORAM"
        mount -t tmpfs -o size=${sqfs_size_mb}M tmpfs "$MNT_TORAM"
        cp "$sqfs_path" "$MNT_TORAM/rootfs.squashfs"
        sqfs_path="$MNT_TORAM/rootfs.squashfs"
        
        log "Squashfs copied to RAM (${sqfs_size_mb}MB)"
    fi
    
    echo "$sqfs_path"
}

#######################################
# Mount Squashfs with Overlay
#######################################

mount_root() {
    local sqfs_path="$1"
    
    log "Mounting squashfs root..."
    
    # Create mount points
    mkdir -p "$MNT_RO" "$MNT_RW" "$MNT_MERGED"
    
    # Mount squashfs (read-only)
    mount -t squashfs -o ro,loop "$sqfs_path" "$MNT_RO" || \
        rescue_shell "Failed to mount squashfs"
    
    check_break "mount"
    
    # Create writable layer
    if [ -n "$PERSISTENT" ]; then
        log "Using persistent storage: $PERSISTENT"
        
        # Wait for device
        case "$PERSISTENT" in
            UUID=*|LABEL=*)
                PERSISTENT=$(findfs "$PERSISTENT") || rescue_shell "Cannot find $PERSISTENT"
                ;;
        esac
        
        local count=0
        while [ ! -b "$PERSISTENT" ] && [ $count -lt $ROOT_TIMEOUT ]; do
            sleep 1
            count=$((count + 1))
        done
        [ -b "$PERSISTENT" ] || rescue_shell "Persistent device not found: $PERSISTENT"
        
        mount "$PERSISTENT" "$MNT_RW" || rescue_shell "Failed to mount persistent storage"
    else
        log "Using tmpfs overlay (size: $OVERLAY_SIZE)"
        mount -t tmpfs -o size=$OVERLAY_SIZE,mode=755 tmpfs "$MNT_RW"
    fi
    
    # Create overlay directories
    mkdir -p "$MNT_RW/upper" "$MNT_RW/work"
    
    # Mount overlay
    log "Mounting overlay filesystem..."
    mount -t overlay overlay \
        -o "lowerdir=$MNT_RO,upperdir=$MNT_RW/upper,workdir=$MNT_RW/work" \
        "$MNT_MERGED" || rescue_shell "Failed to mount overlay"
    
    # Move layer mounts into merged root for visibility
    mkdir -p "$MNT_MERGED/mnt/ro" "$MNT_MERGED/mnt/rw"
    mount --move "$MNT_RO" "$MNT_MERGED/mnt/ro"
    mount --move "$MNT_RW" "$MNT_MERGED/mnt/rw"
    
    if [ "$TORAM" = "1" ] && [ -d "$MNT_TORAM" ]; then
        mkdir -p "$MNT_MERGED/mnt/toram"
        mount --move "$MNT_TORAM" "$MNT_MERGED/mnt/toram"
    fi
    
    log "Root filesystem ready"
}

#######################################
# Switch to Real Root
#######################################

switch_to_root() {
    log "Preparing switch to real root..."
    
    check_break "init"
    
    # Find init binary
    local init="/sbin/init"
    if [ ! -x "$MNT_MERGED$init" ]; then
        for alt in /usr/lib/systemd/systemd /lib/systemd/systemd; do
            if [ -x "$MNT_MERGED$alt" ]; then
                init="$alt"
                break
            fi
        done
    fi
    
    [ -x "$MNT_MERGED$init" ] || rescue_shell "No init found on root"
    
    # Move virtual filesystems
    log "Moving virtual filesystems..."
    mount --move /proc "$MNT_MERGED/proc"
    mount --move /sys "$MNT_MERGED/sys"
    mount --move /dev "$MNT_MERGED/dev"
    mount --move /run "$MNT_MERGED/run"
    
    log "Switching to $init..."
    exec switch_root "$MNT_MERGED" "$init"
    
    rescue_shell "switch_root failed"
}

#######################################
# Main
#######################################

main() {
    log "Ubuntu Squashfs+NetworkManager initramfs starting..."
    log "Kernel: $(uname -r)"
    
    mount_essential
    check_break "top"
    
    parse_cmdline
    load_modules
    check_break "modules"
    
    configure_network
    check_break "premount"
    
    sqfs_path=$(fetch_squashfs)
    mount_root "$sqfs_path"
    check_break "bottom"
    
    switch_to_root
}

# Run main
main "$@"
