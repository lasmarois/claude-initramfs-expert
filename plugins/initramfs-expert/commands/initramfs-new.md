---
name: initramfs-new
description: Initialize a new custom initramfs project with proper directory structure and minimal init script
---

# Create New initramfs Project

Create a new custom initramfs project directory with:
1. Proper directory structure for busybox-based initramfs
2. Minimal working /init script targeting systemd handoff
3. Build script for creating cpio archives
4. README with usage instructions

## Arguments

$ARGUMENTS - Optional: project directory name (default: initramfs)

## Instructions

1. Create the project directory structure:
   ```
   <project>/
   ├── initramfs/           # The actual initramfs contents
   │   ├── bin/
   │   ├── dev/
   │   ├── etc/
   │   ├── lib/
   │   ├── lib64/
   │   ├── mnt/
   │   │   └── root/
   │   ├── proc/
   │   ├── run/
   │   ├── sbin/
   │   ├── sys/
   │   └── init
   ├── build.sh             # Build script
   └── README.md            # Documentation
   ```

2. Copy the minimal-init.sh example from the initramfs-expert skill as the starting /init

3. Create device nodes in dev/:
   - console (c 5 1)
   - null (c 1 3)

4. Create build.sh script that:
   - Validates structure
   - Downloads/copies busybox if not present
   - Creates cpio archive with correct format

5. Generate README.md with:
   - Project overview
   - Build instructions
   - Customization guide
   - Testing with QEMU

After creation, remind the user to:
- Install busybox: `make menuconfig && make LDFLAGS=-static`
- Customize init script for their needs
- Test with QEMU before deploying
