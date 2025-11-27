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

Expert knowledge for designing and building custom Linux initramfs from first principles.

**Includes:**
- `initramfs-architect` agent - Specialized subagent for boot architecture
- `initramfs-reference` skill - Comprehensive reference documentation
- `/initramfs-new` command - Scaffold new initramfs projects

**Use Cases:**
- Custom initramfs without dracut/mkinitcpio
- systemd handoff from shell-based init
- LUKS/LVM integration in early boot
- Boot troubleshooting on RHEL/Rocky Linux

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
│       │       ├── scripts/
│       │       └── examples/
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
