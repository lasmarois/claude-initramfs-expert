# Advanced initramfs Features Reference

This document covers advanced initramfs capabilities including LUKS encryption, LVM, network boot, and Plymouth integration.

## LUKS Encryption Integration

### Required Components

To support LUKS in your initramfs:
- `cryptsetup` binary (statically linked or with required libraries)
- `dm-crypt` and `dm-mod` kernel modules (or built-in)
- Device mapper support

### Basic LUKS Unlock Pattern

```bash
#!/bin/busybox sh

# Load device mapper modules
modprobe dm-crypt
modprobe dm-mod

# Parse crypto parameters from cmdline
# Format: rd.luks.uuid=<uuid> or cryptdevice=UUID=<uuid>:name
parse_crypto_cmdline() {
    for param in $(cat /proc/cmdline); do
        case "$param" in
            rd.luks.uuid=*)
                LUKS_UUID="${param#rd.luks.uuid=}"
                ;;
            cryptdevice=*)
                # Format: UUID=xxx:name or /dev/xxx:name
                local spec="${param#cryptdevice=}"
                LUKS_DEV="${spec%%:*}"
                LUKS_NAME="${spec##*:}"
                ;;
        esac
    done
}

# Prompt for passphrase and unlock
unlock_luks() {
    local device="$1"
    local name="${2:-cryptroot}"
    
    # Resolve UUID if needed
    case "$device" in
        UUID=*)
            device=$(findfs "$device")
            ;;
    esac
    
    echo ""
    echo "LUKS encrypted device detected: $device"
    echo "Enter passphrase to unlock:"
    
    # Try up to 3 times
    local attempts=0
    while [ $attempts -lt 3 ]; do
        if cryptsetup open "$device" "$name"; then
            echo "Device unlocked successfully"
            return 0
        fi
        attempts=$((attempts + 1))
        echo "Incorrect passphrase, attempt $attempts of 3"
    done
    
    return 1
}

# In main init flow:
parse_crypto_cmdline

if [ -n "$LUKS_UUID" ] || [ -n "$LUKS_DEV" ]; then
    device="${LUKS_DEV:-UUID=${LUKS_UUID}}"
    unlock_luks "$device" "${LUKS_NAME:-cryptroot}" || \
        rescue_shell "Failed to unlock LUKS device"
    
    # Root is now /dev/mapper/cryptroot
    root="/dev/mapper/${LUKS_NAME:-cryptroot}"
fi
```

### TPM2-Based Auto-Unlock

For systems with TPM2 (using systemd-cryptenroll):

**Setup (on running system):**
```bash
# Enroll TPM2 key bound to PCR 7 (Secure Boot state)
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/sda2
```

**In initramfs:**
This typically requires systemd components or `tpm2-tools`, making it complex for pure busybox implementations. Consider using dracut for TPM2 scenarios.

### LUKS + LVM Pattern (Common Setup)

```bash
# 1. Unlock LUKS
cryptsetup open /dev/sda2 cryptlvm

# 2. Scan for LVM
pvscan --cache --activate ay
vgchange -ay

# 3. Root is now available
root=/dev/mapper/vg0-root
```

## LVM Integration

### Required Components

- `lvm` binary (or minimal `dmsetup` for simple cases)
- `dm-mod` kernel module

### LVM Activation Pattern

```bash
#!/bin/busybox sh

activate_lvm() {
    # Load device mapper
    modprobe dm-mod
    
    # Method 1: Using lvm tools
    if command -v lvm >/dev/null 2>&1; then
        # Scan and activate all volume groups
        lvm pvscan --cache --activate ay
        lvm vgchange -ay
    
    # Method 2: Minimal - activate specific VG
    elif command -v vgchange >/dev/null 2>&1; then
        vgchange -ay "$VG_NAME"
    fi
    
    # Wait for device mapper devices to appear
    sleep 1
}

# Parse LVM parameters
for param in $(cat /proc/cmdline); do
    case "$param" in
        rd.lvm.vg=*)
            VG_NAME="${param#rd.lvm.vg=}"
            ;;
        rd.lvm.lv=*)
            LV_PATH="${param#rd.lvm.lv=}"
            ;;
    esac
done

# Activate if LVM detected in root specification
case "$root" in
    /dev/mapper/*|/dev/*/*)
        activate_lvm
        ;;
esac
```

### Device Mapper Device Naming

After LVM activation:
- `/dev/mapper/vgname-lvname` - Standard DM path
- `/dev/vgname/lvname` - Symlink created by udev/mdev

## Network Boot (NFS Root)

### Required Components

- Network drivers (kernel modules or built-in)
- `ip` command (from busybox or iproute2)
- NFS client support in kernel

### Network Configuration

Kernel parameter format:
```
ip=<client-ip>::<gateway>:<netmask>:<hostname>:<device>:<autoconf>
ip=dhcp
ip=<device>:dhcp
```

### NFS Root Pattern

```bash
#!/bin/busybox sh

configure_network() {
    local ip_param
    
    # Parse ip= parameter
    for param in $(cat /proc/cmdline); do
        case "$param" in
            ip=*)
                ip_param="${param#ip=}"
                ;;
        esac
    done
    
    case "$ip_param" in
        dhcp)
            # Simple DHCP on first interface
            udhcpc -i eth0 -s /etc/udhcpc.script
            ;;
        *:dhcp)
            # DHCP on specific interface
            local iface="${ip_param%%:*}"
            udhcpc -i "$iface" -s /etc/udhcpc.script
            ;;
        *)
            # Static: ip=client::gateway:netmask:hostname:device:off
            IFS=':' read -r client _ gateway netmask hostname device _ <<< "$ip_param"
            ip link set "$device" up
            ip addr add "${client}/${netmask}" dev "$device"
            ip route add default via "$gateway"
            ;;
    esac
}

mount_nfs_root() {
    local nfs_path="$1"
    local server="${nfs_path%%:*}"
    local path="${nfs_path#*:}"
    
    # Mount NFS root
    mount -t nfs -o ro,nolock "$nfs_path" /mnt/root || \
        rescue_shell "Failed to mount NFS root"
}

# In main:
case "$root" in
    nfs:*|nfs4:*)
        configure_network
        mount_nfs_root "${root#*:}"
        ;;
esac
```

### iSCSI Root

For iSCSI, you need `open-iscsi` tools in initramfs:

```bash
# Start iSCSI daemon
iscsid

# Discovery
iscsiadm -m discovery -t sendtargets -p $ISCSI_TARGET_IP

# Login
iscsiadm -m node -T $ISCSI_TARGET_IQN -p $ISCSI_TARGET_IP --login

# Wait for device
wait_for_device /dev/sda
```

## Plymouth Integration

### Overview

Plymouth provides graphical boot splash and password prompts. For custom initramfs, you need to:
1. Include Plymouth binaries and themes
2. Start plymouthd early
3. Use Plymouth for password prompts

### Basic Integration

```bash
#!/bin/busybox sh

start_plymouth() {
    if [ -x /sbin/plymouthd ]; then
        # Create runtime directory
        mkdir -p /run/plymouth
        
        # Start daemon
        /sbin/plymouthd --attach-to-session \
            --pid-file /run/plymouth/pid \
            --mode=boot
        
        # Show splash
        /bin/plymouth --show-splash
    fi
}

plymouth_ask_password() {
    local prompt="$1"
    
    if [ -x /bin/plymouth ] && plymouth --ping 2>/dev/null; then
        plymouth ask-for-password --prompt="$prompt"
    else
        # Fallback to console
        echo -n "$prompt "
        read -s password
        echo
        echo "$password"
    fi
}

stop_plymouth() {
    if [ -x /bin/plymouth ]; then
        plymouth --quit
    fi
}

# Usage for LUKS:
passphrase=$(plymouth_ask_password "Enter LUKS passphrase:")
echo -n "$passphrase" | cryptsetup open /dev/sda2 cryptroot -
```

## Microcode Loading

### Early Microcode Architecture

CPU microcode should be loaded as early as possible. The kernel supports an early cpio prepended to the main initramfs.

### Building Microcode Archive

```bash
#!/bin/bash

# Intel microcode
mkdir -p kernel/x86/microcode
cat /lib/firmware/intel-ucode/* > kernel/x86/microcode/GenuineIntel.bin

# Or AMD
# cat /lib/firmware/amd-ucode/* > kernel/x86/microcode/AuthenticAMD.bin

# Create uncompressed cpio
find kernel | cpio -o -H newc > /tmp/early-ucode.cpio

# Concatenate with main initramfs
cat /tmp/early-ucode.cpio /boot/initramfs.img.gz > /boot/initramfs-combined.img
```

### Kernel Detection

The kernel automatically detects and loads the early microcode archive if:
- It's the first (uncompressed) cpio in the initramfs
- The path matches `kernel/x86/microcode/{GenuineIntel,AuthenticAMD}.bin`

## Debugging Strategies

### QEMU Testing

```bash
# Basic test
qemu-system-x86_64 \
    -kernel /boot/vmlinuz \
    -initrd /boot/initramfs.img \
    -append "root=/dev/sda1 console=ttyS0 rd.shell" \
    -nographic \
    -hda test-disk.img

# With networking (for NFS testing)
qemu-system-x86_64 \
    -kernel /boot/vmlinuz \
    -initrd /boot/initramfs.img \
    -append "root=nfs:10.0.2.2:/srv/nfsroot ip=dhcp console=ttyS0" \
    -nographic \
    -netdev user,id=net0 \
    -device virtio-net,netdev=net0

# With encryption testing
qemu-system-x86_64 \
    -kernel /boot/vmlinuz \
    -initrd /boot/initramfs.img \
    -append "root=/dev/mapper/cryptroot rd.luks.uuid=xxx console=ttyS0" \
    -nographic \
    -hda encrypted-disk.img
```

### Debug Output

```bash
# Add to init script
DEBUG=0
for param in $(cat /proc/cmdline); do
    case "$param" in
        rd.debug) DEBUG=1 ;;
    esac
done

debug_log() {
    [ "$DEBUG" = "1" ] && echo "[DEBUG] $*"
}

# Use throughout script
debug_log "Mounting /dev"
debug_log "Root device: $root"
debug_log "Available block devices: $(ls /dev/[hsv]d* 2>/dev/null)"
```

### Common Debug Breakpoints

Add these to your init script:

```bash
break_if_requested() {
    local stage="$1"
    if grep -q "rd.break=$stage" /proc/cmdline; then
        echo "=== Break at $stage ==="
        echo "Type 'exit' to continue"
        /bin/sh
    fi
}

# Use throughout init
break_if_requested "pre-udev"
# ... mount devtmpfs ...
break_if_requested "pre-mount"
# ... mount root ...
break_if_requested "pre-pivot"
# ... switch_root ...
```
