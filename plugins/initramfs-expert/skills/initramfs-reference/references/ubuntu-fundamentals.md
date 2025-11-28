# Ubuntu initramfs Fundamentals Reference

This document covers Ubuntu-specific initramfs architecture for 22.04 LTS (Jammy) and 24.04 LTS (Noble), with focus on building custom busybox-based initramfs that bypasses initramfs-tools entirely.

## Ubuntu vs RHEL Architectural Differences

| Aspect | Ubuntu (initramfs-tools) | RHEL (dracut) |
|--------|--------------------------|---------------|
| Default strategy | MODULES=most (portable) | hostonly (minimal) |
| Module definition | PREREQ variable in script | check/depends/install functions |
| Shell environment | Busybox or klibc | Full bash + glibc |
| Hook locations | /usr/share/initramfs-tools/hooks/ | /usr/lib/dracut/modules.d/NNname/ |
| Debug parameter | `break=stage` | `rd.break=stage` |
| Config file | /etc/initramfs-tools/initramfs.conf | /etc/dracut.conf |
| Rebuild command | `update-initramfs -u` | `dracut -f` |

## initramfs-tools Architecture (Reference Only)

Understanding initramfs-tools helps when debugging or borrowing patterns, even when building fully custom initramfs.

### Boot Stage Execution Order

Scripts execute through seven ordered stages:

```
1. init-top        → After sysfs/procfs mount, before udev
2. init-premount   → After module loading, udev running
3. local-top       → Root device expected to exist
4. local-block     → Device discovery loop (runs repeatedly)
5. local-premount  → Pre-mount verification
6. local-bottom    → After root mount
7. init-bottom     → Cleanup before switch_root
```

### Script PREREQ System

Each script declares dependencies:

```bash
#!/bin/sh
PREREQ="udev"
prereqs()
{
    echo "$PREREQ"
}
case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

# Script content here
```

### Key Directories

```
/usr/share/initramfs-tools/
├── hooks/              # Build-time hooks (copy files into initramfs)
├── scripts/            # Boot-time scripts
│   ├── init-top/
│   ├── init-premount/
│   ├── local-top/
│   ├── local-block/
│   ├── local-premount/
│   ├── local-bottom/
│   └── init-bottom/
└── modules.d/          # Module lists

/etc/initramfs-tools/
├── initramfs.conf      # Main configuration
├── conf.d/             # Config overrides
├── hooks/              # Local build-time hooks
├── scripts/            # Local boot-time scripts
└── modules             # Additional modules to include
```

### initramfs.conf Options

```bash
# /etc/initramfs-tools/initramfs.conf

# Module inclusion strategy
MODULES=most      # Include broad hardware support (default, portable)
MODULES=dep       # Guess from current hardware
MODULES=list      # Only explicitly specified modules
MODULES=netboot   # Network modules, skip block devices

# Busybox or klibc
BUSYBOX=auto      # Use busybox if available

# Compression
COMPRESS=zstd     # Options: gzip, lz4, xz, zstd, lzma

# Resume device for hibernation
RESUME=           # e.g., /dev/sda2 or UUID=...
```

### Useful Helper Functions (in hooks)

```bash
# Copy binary with all library dependencies
copy_exec /usr/bin/someprogram /bin/

# Copy kernel module and dependencies
manual_add_modules ext4 squashfs overlay

# Force module to load at boot
force_load dm-crypt

# Copy file preserving path
copy_file library /lib/x86_64-linux-gnu/libfoo.so.1
```

## Building Custom initramfs on Ubuntu

### Installing busybox-static

```bash
# Option 1: Ubuntu package (recommended for compatibility)
apt install busybox-static
cp /bin/busybox-static /path/to/initramfs/bin/busybox

# Option 2: Compile from source (latest features)
wget https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar -xjf busybox-1.36.1.tar.bz2
cd busybox-1.36.1
make defconfig
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
make -j$(nproc)
cp busybox /path/to/initramfs/bin/
```

### Minimal Directory Structure

```
initramfs/
├── bin/
│   └── busybox              # Statically linked (~2MB)
├── dev/
│   ├── console              # mknod -m 600 console c 5 1
│   └── null                 # mknod -m 666 null c 1 3
├── etc/
├── lib/
│   └── modules/             # Kernel modules if needed
│       └── $(uname -r)/
├── lib64 -> lib             # Symlink for compatibility
├── mnt/
│   └── root/                # Mount point for real root
├── proc/
├── run/
├── sbin -> bin              # Symlink
├── sys/
├── tmp/
└── init                     # Must be executable!
```

### Critical: devtmpfs is NOT Auto-Mounted

Despite `CONFIG_DEVTMPFS_MOUNT=y` in Ubuntu kernels, devtmpfs is **NOT** automatically mounted when using initramfs. Your init script MUST mount it:

```bash
mount -t devtmpfs devtmpfs /dev
```

Without this, you'll have no device nodes except the pre-created console and null.

### Ubuntu Kernel Module Locations

```bash
# Modules directory
/lib/modules/$(uname -r)/

# Find specific module
find /lib/modules/$(uname -r) -name "squashfs.ko*"

# List module dependencies
modinfo -F depends squashfs

# Copy module with dependencies for initramfs
# Use this pattern in build script:
for mod in squashfs overlay loop; do
    modprobe --show-depends "$mod" 2>/dev/null | \
        awk '/^insmod/ {print $2}' | \
        while read modpath; do
            dest="initramfs/lib/modules/$(uname -r)/$(basename $modpath)"
            mkdir -p "$(dirname $dest)"
            cp "$modpath" "$dest"
        done
done
depmod -b initramfs $(uname -r)
```

### Essential Modules for Common Scenarios

**Storage (SATA/NVMe/USB):**
```
ahci            # SATA AHCI controller
nvme            # NVMe controller
nvme_core       # NVMe core
sd_mod          # SCSI disk
usb_storage     # USB mass storage
uas             # USB Attached SCSI
```

**Filesystems:**
```
ext4            # ext4 filesystem
squashfs        # Squashfs (read-only compressed)
overlay         # Overlayfs
loop            # Loop device (for mounting files)
iso9660         # ISO images
```

**Network:**
```
af_packet       # Required for NetworkManager
e1000e          # Intel Gigabit (common server)
igb             # Intel Gigabit (newer)
ixgbe           # Intel 10Gbe
virtio_net      # KVM/QEMU virtio
```

**Device Mapper (for LVM/LUKS):**
```
dm_mod          # Device mapper core
dm_crypt        # Encryption
dm_snapshot     # Snapshots
```

## Device Naming on Ubuntu

### Predictable Network Interface Names

Ubuntu uses systemd's predictable naming by default:
- `enp0s3` - PCI bus 0, slot 3
- `ens192` - PCI hotplug slot 192
- `eno1` - Onboard device 1

**Disable for traditional naming (eth0):**
```bash
# Kernel command line
net.ifnames=0 biosdevname=0
```

In minimal initramfs without udev, traditional naming applies automatically.

### Block Device Naming

```
/dev/sda, /dev/sdb...      # SATA/SAS/USB
/dev/nvme0n1, /dev/nvme1n1 # NVMe
/dev/vda, /dev/vdb...      # Virtio (KVM/QEMU)
/dev/xvda, /dev/xvdb...    # Xen
/dev/mmcblk0, /dev/mmcblk1 # MMC/SD cards
```

Partitions append number: `/dev/sda1`, `/dev/nvme0n1p1`

## Ubuntu-Specific Kernel Parameters

### initramfs-tools Parameters

```bash
# Drop to shell at stage
break=premount              # Before mounting root
break=mount                 # During mount
break=bottom                # After mount
break=init                  # Before switch_root

# Multiple breakpoints
break=premount,mount,init

# Debug logging
debug                       # Writes to /run/initramfs/initramfs.debug

# Root specification
root=/dev/sda1
root=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
root=LABEL=rootfs

# Root options
rootflags=subvol=@          # Btrfs subvolume
rootfstype=ext4             # Force filesystem type
ro                          # Mount read-only initially
rw                          # Mount read-write

# Wait for root device
rootdelay=10                # Wait N seconds
rootwait                    # Wait indefinitely
```

### Network Boot Parameters

```bash
# DHCP on all interfaces
ip=dhcp

# DHCP on specific interface
ip=eth0:dhcp

# Static configuration
ip=192.168.1.100::192.168.1.1:255.255.255.0:hostname:eth0:off

# Format: ip=client::gateway:netmask:hostname:device:autoconf
# autoconf: off, dhcp, on (DHCP+RARP+BOOTP), any

# NFS root
root=nfs:192.168.1.1:/srv/nfsroot
nfsroot=192.168.1.1:/srv/nfsroot,tcp,vers=4
```

### Disabling Ubuntu Services in Boot

```bash
# Disable cloud-init
cloud-init=disabled

# Disable AppArmor
apparmor=0

# Disable splash
nosplash

# Verbose boot
quiet                       # Remove this for verbose
loglevel=7                  # Maximum kernel verbosity
```

## Building the Initramfs Archive

### Correct cpio Creation

```bash
cd /path/to/initramfs
find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../initramfs.img

# Or with zstd compression (faster, better ratio)
find . -print0 | cpio --null -ov --format=newc | zstd -19 > ../initramfs.img.zst
```

**Critical**: Do NOT use `find -depth` — directories must precede their contents.

### Verification

```bash
# Check archive format
file initramfs.img

# List contents
zcat initramfs.img | cpio -tv | head -50

# Extract for inspection
mkdir /tmp/initramfs-check
cd /tmp/initramfs-check
zcat /path/to/initramfs.img | cpio -idmv
```

## GRUB2 Configuration on Ubuntu

### Adding Custom Entry

```bash
# /etc/grub.d/40_custom

menuentry 'Ubuntu Custom Initramfs' --class ubuntu {
    insmod gzio
    insmod part_gpt
    insmod ext2
    set root='hd0,gpt2'
    linux /boot/vmlinuz-custom root=UUID=YOUR-UUID ro debug
    initrd /boot/initrd-custom.img
}
```

Then run:
```bash
update-grub
```

### Testing Without Modifying GRUB

From GRUB menu, press `e` to edit, modify linux/initrd lines, press `Ctrl+X` to boot.

### Recovery Entry

Always keep a working recovery option:
```bash
menuentry 'Ubuntu Recovery (Stock Initramfs)' --class ubuntu {
    insmod gzio
    insmod part_gpt  
    insmod ext2
    set root='hd0,gpt2'
    linux /boot/vmlinuz-$(uname -r) root=UUID=YOUR-UUID ro single
    initrd /boot/initrd.img-$(uname -r)
}
```

## Secure Boot Considerations

Ubuntu's Secure Boot chain validates:
1. Shim (signed by Microsoft)
2. GRUB (signed by Canonical)
3. Kernel (signed by Canonical)

**Initramfs is NOT validated** — it's loaded by the kernel after Secure Boot verification completes.

For custom kernels:
```bash
# Generate MOK (Machine Owner Key)
openssl req -new -x509 -newkey rsa:2048 -keyout MOK.key -out MOK.crt -nodes -days 3650 -subj "/CN=Custom Kernel/"

# Enroll MOK
mokutil --import MOK.crt
# Reboot, follow prompts

# Sign kernel
sbsign --key MOK.key --cert MOK.crt --output vmlinuz-signed vmlinuz-custom
```

## Cloud-init Interaction

Cloud-init runs early in boot and can conflict with custom networking.

### Disabling Cloud-init

```bash
# Method 1: Kernel parameter
cloud-init=disabled

# Method 2: Disable file
touch /etc/cloud/cloud-init.disabled

# Method 3: Mask services
systemctl mask cloud-init.service cloud-init-local.service \
    cloud-config.service cloud-final.service
```

### NoCloud Datasource (for local use)

If keeping cloud-init for local provisioning:

```bash
# Create seed directory
mkdir -p /var/lib/cloud/seed/nocloud

# meta-data (required, can be minimal)
cat > /var/lib/cloud/seed/nocloud/meta-data << 'EOF'
instance-id: local01
local-hostname: myhost
EOF

# user-data (optional)
cat > /var/lib/cloud/seed/nocloud/user-data << 'EOF'
#cloud-config
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-rsa AAAA...
EOF
```

## References

- Ubuntu initramfs-tools manpage: https://manpages.ubuntu.com/manpages/noble/man8/initramfs-tools.8.html
- Debian initramfs-tools documentation: https://manpages.debian.org/testing/initramfs-tools-core/initramfs-tools.7.en.html
- Ubuntu Wiki Boot Process: https://wiki.ubuntu.com/BootProcess
- systemd initrd interface: https://systemd.io/INITRD_INTERFACE/
