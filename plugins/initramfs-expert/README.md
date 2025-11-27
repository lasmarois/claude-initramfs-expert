# initramfs Expert Plugin

A Claude Code plugin providing specialized expertise for designing and building custom Linux initramfs implementations from first principles.

## Overview

This plugin is designed for DevOps engineers and system administrators who need to:
- Build custom initramfs without relying on dracut, mkinitcpio, or initramfs-tools
- Understand the kernel's boot contract and initramfs requirements
- Implement clean handoff from busybox/shell init to systemd
- Debug early boot issues on RHEL/Rocky Linux systems

## Components

### Agent: initramfs-architect

A specialized subagent with deep expertise in:
- Kernel initramfs contract (cpio format, /init requirements, switch_root)
- busybox-based init script design
- Device discovery strategies (devtmpfs, mdev)
- systemd interface requirements
- LUKS/LVM integration patterns

The agent is automatically invoked when discussing:
- Custom initramfs architecture
- Early boot troubleshooting
- Boot process design
- Kernel parameter configuration

### Skill: initramfs-reference

Comprehensive reference documentation organized for progressive disclosure:

**SKILL.md** - Quick reference for common tasks:
- Kernel contract summary
- Critical mounting order
- switch_root requirements
- systemd handoff checklist

**references/** - Detailed documentation:
- `kernel-documentation.md` - Official kernel initramfs contract
- `design-patterns.md` - Production init script patterns
- `systemd-handoff.md` - systemd interface requirements  
- `advanced-features.md` - LUKS, LVM, network boot, Plymouth

**examples/** - Working code:
- `minimal-init.sh` - Bare minimum bootable init script

**scripts/** - Utilities:
- `validate-initramfs.sh` - Validate initramfs structure

### Command: /initramfs-new

Slash command to scaffold a new initramfs project with proper structure.

## Installation

### From Marketplace

```bash
# Add the marketplace
/plugin marketplace add lasmarois/claude-initramfs-expert

# Install the plugin
/plugin install initramfs-expert@claude-initramfs-expert
```

### Local Installation

```bash
# Clone the repository
git clone https://github.com/lasmarois/claude-initramfs-expert

# Add as local marketplace
/plugin marketplace add ./claude-initramfs-expert
```

## Usage

### Automatic Invocation

The agent and skill activate automatically when you discuss:
- "I need to build a custom initramfs"
- "Help me debug early boot on Rocky Linux"
- "How does switch_root work?"
- "LUKS encryption in initramfs"

### Manual Invocation

```
# Use the agent explicitly
Use the initramfs-architect agent to review my init script

# Create a new project
/initramfs-new my-custom-initramfs

# Access skill documentation
Read the kernel-documentation.md from initramfs-reference skill
```

## Target Environment

This plugin targets:
- **Distributions**: Rocky Linux, RHEL, Fedora, CentOS Stream
- **Init System**: systemd
- **Implementation**: busybox + shell scripts (no dracut)
- **Use Cases**: Custom appliances, embedded systems, specialized boot requirements

## Requirements

No external dependencies. The plugin provides documentation and patterns that work with:
- busybox (statically compiled)
- Standard shell utilities
- Linux kernel 4.x+

## License

MIT License

## Contributing

Contributions welcome! Please submit issues and pull requests to improve:
- Documentation accuracy
- Additional patterns and examples
- Support for more advanced scenarios

## References

- [Kernel initramfs documentation](https://www.kernel.org/doc/html/latest/filesystems/ramfs-rootfs-initramfs.html)
- [systemd initrd interface](https://systemd.io/INITRD_INTERFACE/)
- [Linux From Scratch initramfs](https://www.linuxfromscratch.org/blfs/view/svn/postlfs/initramfs.html)
