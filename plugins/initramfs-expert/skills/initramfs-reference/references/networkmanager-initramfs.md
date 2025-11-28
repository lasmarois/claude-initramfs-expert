# NetworkManager in Initramfs Reference

This document covers running NetworkManager in custom initramfs environments, bypassing netplan, and configuring network-dependent root scenarios like NFS, iSCSI, or HTTP-fetched squashfs images.

## Overview

NetworkManager supports a special **initrd mode** (`configure-and-quit=initrd`) designed for initramfs environments where:
- D-Bus is not available
- Network must be configured before root mount
- Configuration should persist to main system

This mode configures interfaces, waits for connectivity, then exits—perfect for:
- NFS root filesystems
- iSCSI boot
- HTTP/HTTPS fetched squashfs images
- PXE boot with network-dependent root

## NetworkManager initrd Mode

### How It Works

```
1. NetworkManager starts without D-Bus dependency
2. Reads connection profiles from /etc/NetworkManager/system-connections/
3. Applies configuration (DHCP or static)
4. Waits for connectivity
5. Writes runtime state to /run/NetworkManager/
6. Exits cleanly
7. switch_root preserves /run for main system NetworkManager
```

### Configuration File

```ini
# /etc/NetworkManager/NetworkManager.conf (in initramfs)

[main]
# Use keyfile plugin (no dbus required)
plugins=keyfile

# Critical: initrd mode - configure and exit
configure-and-quit=initrd

# Don't auto-create connections for unmanaged devices
no-auto-default=*

# Use internal DHCP client (no external dependencies)
dhcp=internal

[logging]
level=INFO
# Options: ERR, WARN, INFO, DEBUG, TRACE

[connection]
# Apply to all connections
ipv6.method=disabled
```

### Required Files in Initramfs

**Binaries:**
```
/usr/sbin/NetworkManager
/usr/bin/nm-online              # Wait for connectivity
/usr/libexec/nm-dhcp-helper     # DHCP client helper
/usr/lib/NetworkManager/        # NM modules
```

**Libraries (discover with ldd):**
```bash
ldd /usr/sbin/NetworkManager
# Key libraries:
# libnm.so
# libglib-2.0.so
# libgio-2.0.so
# libgobject-2.0.so
# libndp.so (Neighbor Discovery Protocol)
# libudev.so
# libsystemd.so (for sd-event)
```

**Configuration:**
```
/etc/NetworkManager/NetworkManager.conf
/etc/NetworkManager/system-connections/*.nmconnection
```

### Copying Dependencies for Initramfs

Using initramfs-tools `copy_exec`:

```bash
#!/bin/sh
# /etc/initramfs-tools/hooks/networkmanager

PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac

. /usr/share/initramfs-tools/hook-functions

# Copy NetworkManager binaries
copy_exec /usr/sbin/NetworkManager /usr/sbin/
copy_exec /usr/bin/nm-online /usr/bin/
copy_exec /usr/libexec/nm-dhcp-helper /usr/libexec/

# Copy configuration
mkdir -p "${DESTDIR}/etc/NetworkManager/system-connections"
cp /etc/NetworkManager/NetworkManager.conf "${DESTDIR}/etc/NetworkManager/"
cp /etc/NetworkManager/system-connections/*.nmconnection "${DESTDIR}/etc/NetworkManager/system-connections/" 2>/dev/null || true

# Copy NM plugins
mkdir -p "${DESTDIR}/usr/lib/NetworkManager"
cp -a /usr/lib/NetworkManager/* "${DESTDIR}/usr/lib/NetworkManager/"
```

## Connection Profiles (Keyfile Format)

### DHCP Connection

```ini
# /etc/NetworkManager/system-connections/dhcp.nmconnection
# File permissions MUST be 0600

[connection]
id=Wired DHCP
uuid=27afa607-ee36-43f0-b8c3-9d245cdc4bb3
type=ethernet
autoconnect=true
autoconnect-priority=100

[ethernet]
# Optional: specific MAC
# mac-address=00:11:22:33:44:55

[ipv4]
method=auto
dhcp-timeout=60
may-fail=false
# Required for network-dependent root
route-metric=100

[ipv6]
method=disabled
```

### Static IP Connection

```ini
# /etc/NetworkManager/system-connections/static.nmconnection

[connection]
id=Static Network
uuid=550e8400-e29b-41d4-a716-446655440000
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]

[ipv4]
method=manual
addresses=192.168.1.100/24
gateway=192.168.1.1
dns=8.8.8.8;8.8.4.4;
dns-search=example.com;
may-fail=false

[ipv6]
method=disabled
```

### VLAN Connection

```ini
# /etc/NetworkManager/system-connections/vlan100.nmconnection

[connection]
id=VLAN 100
uuid=a1b2c3d4-e5f6-7890-abcd-ef1234567890
type=vlan
autoconnect=true

[vlan]
id=100
parent=eth0

[ipv4]
method=auto
may-fail=false

[ipv6]
method=disabled
```

### Bond Connection

```ini
# /etc/NetworkManager/system-connections/bond0.nmconnection

[connection]
id=Bond
uuid=bond-uuid-here
type=bond
interface-name=bond0
autoconnect=true

[bond]
mode=802.3ad
miimon=100
lacp_rate=fast

[ipv4]
method=auto
may-fail=false

[ipv6]
method=disabled

---
# Slave connection 1
# /etc/NetworkManager/system-connections/bond0-slave1.nmconnection

[connection]
id=Bond Slave 1
uuid=slave1-uuid
type=ethernet
interface-name=eth0
master=bond0
slave-type=bond
autoconnect=true

[ethernet]
```

### Generate UUID

```bash
# Using uuidgen
uuidgen

# Using Python
python3 -c "import uuid; print(uuid.uuid4())"

# Using /proc
cat /proc/sys/kernel/random/uuid
```

## Init Script Integration

### Complete NetworkManager Boot Script

```bash
#!/bin/busybox sh
#
# NetworkManager initialization for initramfs
#

NM_TIMEOUT="${NM_TIMEOUT:-60}"

start_networkmanager() {
    echo "Starting NetworkManager in initrd mode..."
    
    # Create required directories
    mkdir -p /run/NetworkManager/system-connections
    mkdir -p /var/run
    ln -sf /run /var/run
    
    # Required for NM to detect interfaces
    if [ ! -d /sys/class/net ]; then
        echo "ERROR: /sys not mounted"
        return 1
    fi
    
    # Load network driver if needed
    modprobe af_packet 2>/dev/null || true
    
    # Start NetworkManager
    /usr/sbin/NetworkManager --configure-and-quit=initrd --no-daemon &
    NM_PID=$!
    
    # Wait for NetworkManager to configure network
    echo "Waiting for network (timeout: ${NM_TIMEOUT}s)..."
    if /usr/bin/nm-online -t "$NM_TIMEOUT" -s; then
        echo "Network is online"
    else
        echo "WARNING: Network configuration timeout"
        # Don't fail - might still work for some scenarios
    fi
    
    # Wait for NM to exit (it will after configure-and-quit)
    wait $NM_PID 2>/dev/null || true
    
    return 0
}

stop_networkmanager() {
    # NetworkManager in initrd mode exits automatically
    # But ensure cleanup
    killall NetworkManager 2>/dev/null || true
}

preserve_network_state() {
    # Preserve state for handoff to main system
    if [ -d /run/NetworkManager ]; then
        mkdir -p /run/initramfs/state
        cp -a /run/NetworkManager /run/initramfs/state/
    fi
}

# Usage in main init:
# start_networkmanager || rescue_shell "Network configuration failed"
# ... download squashfs, mount NFS, etc ...
# preserve_network_state
# switch_root ...
```

### Waiting for Specific Interface

```bash
wait_for_interface() {
    local iface="$1"
    local timeout="${2:-30}"
    local count=0
    
    while [ $count -lt $timeout ]; do
        if ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
            # Check for IP address
            if ip addr show "$iface" | grep -q "inet "; then
                echo "Interface $iface is ready"
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    
    echo "Timeout waiting for $iface"
    return 1
}
```

## Bypassing Netplan on Ubuntu

### Ubuntu 22.04 LTS

Netplan can be fully removed:

```bash
apt remove --purge netplan.io
rm -rf /etc/netplan
```

Configure NetworkManager directly:
```bash
# /etc/NetworkManager/NetworkManager.conf
[main]
plugins=keyfile
dns=default

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
```

### Ubuntu 24.04 LTS

Netplan is a dependency of network-manager package and cannot be removed. Instead, configure netplan as passthrough:

```yaml
# /etc/netplan/01-network-manager-all.yaml
network:
  version: 2
  renderer: NetworkManager
```

Then apply:
```bash
netplan generate
netplan apply
```

### Disable Netplan in Initramfs

For custom initramfs, simply don't include netplan. NetworkManager works standalone with keyfile plugin.

```ini
# /etc/NetworkManager/NetworkManager.conf in initramfs
[main]
plugins=keyfile
# No netplan reference needed
```

## Kernel Command Line Network Configuration

### nm-initrd-generator

NetworkManager includes `nm-initrd-generator` which parses kernel command line and generates connection profiles:

```bash
# Generate profiles from kernel params
/usr/libexec/nm-initrd-generator -- \
    ip=192.168.1.100::192.168.1.1:255.255.255.0:myhost:eth0:off \
    rd.neednet=1

# Output goes to /run/NetworkManager/system-connections/
```

### Supported Kernel Parameters

```bash
# DHCP on all interfaces
ip=dhcp
rd.neednet=1

# DHCP on specific interface  
ip=eth0:dhcp

# Static IP
ip=192.168.1.100::192.168.1.1:255.255.255.0:hostname:eth0:off

# Format: ip=<client>:<server>:<gateway>:<netmask>:<hostname>:<device>:<autoconf>
# autoconf: off, dhcp, on, any

# Multiple interfaces
ip=eth0:dhcp ip=eth1:dhcp

# VLAN
vlan=vlan100:eth0

# Bond
bond=bond0:eth0,eth1:mode=802.3ad,miimon=100
ip=bond0:dhcp

# Bridge
bridge=br0:eth0

# Force NetworkManager in initrd (dracut)
rd.neednet=1
```

### Init Script Using nm-initrd-generator

```bash
configure_network_from_cmdline() {
    # Parse kernel command line and generate profiles
    /usr/libexec/nm-initrd-generator -- $(cat /proc/cmdline)
    
    # Profiles now in /run/NetworkManager/system-connections/
    # Start NetworkManager to apply them
    /usr/sbin/NetworkManager --configure-and-quit=initrd &
    /usr/bin/nm-online -t 60
}
```

## Network-Dependent Root Scenarios

### NFS Root

```bash
# Kernel parameters
root=nfs:192.168.1.1:/srv/nfsroot ip=dhcp

# Init script
start_networkmanager
mount -t nfs -o vers=4,tcp 192.168.1.1:/srv/nfsroot /mnt/root
```

### iSCSI Root

```bash
# Kernel parameters
root=iscsi:192.168.1.1::3260:1:iqn.2024.com.example:storage ip=dhcp

# Init script (requires open-iscsi)
start_networkmanager
iscsiadm -m discovery -t sendtargets -p 192.168.1.1
iscsiadm -m node -T iqn.2024.com.example:storage -p 192.168.1.1 --login
# Wait for /dev/sda to appear
```

### HTTP-Fetched Squashfs

```bash
# Kernel parameters
squashfs=http://192.168.1.1/images/rootfs.squashfs ip=dhcp

# Init script
start_networkmanager

# Download squashfs
wget -O /tmp/rootfs.squashfs "http://192.168.1.1/images/rootfs.squashfs"
# Or with curl:
# curl -o /tmp/rootfs.squashfs "http://192.168.1.1/images/rootfs.squashfs"

# Mount and continue
mount -t squashfs -o ro,loop /tmp/rootfs.squashfs /mnt/ro
```

## Handoff to Main System

### Preserving Network State

NetworkManager stores runtime state in `/run/NetworkManager/`. This must survive switch_root:

```bash
# Before switch_root
mount --move /run /mnt/root/run

# Or explicitly preserve
mkdir -p /mnt/root/run/NetworkManager
cp -a /run/NetworkManager/* /mnt/root/run/NetworkManager/
```

### Main System NetworkManager Behavior

When the main system's NetworkManager starts, it:
1. Detects existing state in `/run/NetworkManager/`
2. Assumes control of already-configured interfaces
3. Continues with same IP configuration
4. No network disruption

### Connection Files Location

| Environment | Profile Location |
|-------------|-----------------|
| Initramfs | /etc/NetworkManager/system-connections/ (in initramfs) |
| Runtime | /run/NetworkManager/system-connections/ |
| Main System | /etc/NetworkManager/system-connections/ |

## Troubleshooting

### Debug Logging

```ini
# /etc/NetworkManager/NetworkManager.conf
[logging]
level=TRACE
domains=ALL

# Or via command line:
# /usr/sbin/NetworkManager --log-level=TRACE --log-domains=ALL
```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| "No suitable device found" | NIC driver not loaded | `modprobe <driver>` |
| "Connection activation failed" | Permission on .nmconnection | `chmod 600 *.nmconnection` |
| nm-online timeout | No carrier/DHCP failure | Check cable, DHCP server |
| "Failed to find expected interface" | Wrong interface name | Use `ip link` to find actual name |
| D-Bus errors | Wrong mode | Use `configure-and-quit=initrd` |

### Checking Network State

```bash
# In initramfs shell (after break=premount)

# List interfaces
ip link

# Check IP addresses
ip addr

# Check routes
ip route

# Check DNS (if resolvconf working)
cat /etc/resolv.conf
cat /run/NetworkManager/resolv.conf

# NetworkManager state
ls -la /run/NetworkManager/

# Check logs
dmesg | grep -i eth
dmesg | grep -i network
```

### Manual Network Configuration (Fallback)

If NetworkManager fails, configure manually:

```bash
# Load driver
modprobe e1000e  # or appropriate driver

# Bring up interface
ip link set eth0 up

# DHCP (using busybox)
udhcpc -i eth0 -s /etc/udhcpc/default.script

# Or static
ip addr add 192.168.1.100/24 dev eth0
ip route add default via 192.168.1.1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

## References

- NetworkManager documentation: https://networkmanager.dev/docs/
- nm-settings-keyfile: https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html
- NetworkManager initrd support: https://www.redhat.com/en/blog/network-confi-initrd
- nm-initrd-generator: https://networkmanager.dev/docs/api/latest/nm-initrd-generator.html
