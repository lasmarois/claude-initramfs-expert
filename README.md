# initramfs Expert Marketplace

A Claude Code plugin marketplace providing specialized tools for Linux early boot and custom initramfs development.

## Quick Start

```bash
# Add this marketplace to Claude Code
/plugin marketplace add lasmarois/claude-initramfs-expert

# Browse available plugins
/plugin

# Install the initramfs expert plugin
/plugin install initramfs-expert@claude-initramfs-expert
```

## Available Plugins

### initramfs-expert

Expert knowledge for designing and building custom Linux initramfs from first principles, supporting both RHEL/Rocky and Ubuntu LTS distributions.

**Includes:**
- `initramfs-architect` agent - Specialized subagent for boot architecture
- `initramfs-reference` skill - Comprehensive reference documentation
- `/initramfs-new` command - Scaffold new initramfs projects

**Core Knowledge:**
- Kernel boot contracts and cpio archive format
- switch_root mechanics and systemd handoff
- LUKS/LVM integration in early boot
- Device discovery strategies

**Ubuntu-Specific Knowledge:**
- initramfs-tools vs dracut architecture differences
- Squashfs root with overlayfs (live systems, diskless workstations)
- NetworkManager in initrd mode (no D-Bus required)
- Network-dependent root: NFS, iSCSI, HTTP-fetched images
- Casper/toram patterns for copy-to-RAM boot
- Bypassing netplan with keyfile profiles

**Use Cases:**
- Custom initramfs without dracut/mkinitcpio
- Diskless workstations booting from network
- Live USB/CD systems with persistent overlay
- Kiosk and appliance deployments
- Boot troubleshooting on RHEL/Rocky and Ubuntu

[Read more →](./plugins/initramfs-expert/README.md)

## Repository Structure

```
claude-initramfs-expert/
├── .claude-plugin/
│   └── marketplace.json       # Marketplace definition
├── plugins/
│   └── initramfs-expert/      # The initramfs expert plugin
│       ├── .claude-plugin/
│       │   └── plugin.json
│       ├── agents/
│       │   └── initramfs-architect.md
│       ├── skills/
│       │   └── initramfs-reference/
│       │       ├── SKILL.md
│       │       ├── references/
│       │       │   ├── kernel-documentation.md
│       │       │   ├── design-patterns.md
│       │       │   ├── systemd-handoff.md
│       │       │   ├── advanced-features.md
│       │       │   ├── ubuntu-fundamentals.md
│       │       │   ├── squashfs-overlay.md
│       │       │   └── networkmanager-initramfs.md
│       │       ├── examples/
│       │       │   ├── minimal-init.sh
│       │       │   └── ubuntu-squashfs-nm-init.sh
│       │       └── scripts/
│       │           └── validate-initramfs.sh
│       ├── commands/
│       │   └── initramfs-new.md
│       └── README.md
└── README.md                  # This file
```

## For Plugin Developers

### Adding New Plugins

1. Create a new directory under `plugins/`
2. Add `.claude-plugin/plugin.json` manifest
3. Add your agents, skills, commands, and hooks
4. Update `marketplace.json` with the new plugin entry

### Marketplace Format

```json
{
  "name": "marketplace-name",
  "plugins": [
    {
      "name": "plugin-name",
      "source": "./plugins/plugin-name",
      "description": "Plugin description",
      "version": "1.0.0"
    }
  ]
}
```

## License

MIT License

## Contributing

Contributions welcome! If you have expertise in related areas:
- Additional boot scenarios (PXE, iSCSI, etc.)
- Other distributions
- Advanced debugging techniques

Please submit a pull request.
