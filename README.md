# 🐳 Docker Volume Backup & Migration Tool

A comprehensive container-aware backup solution for Docker volumes with automated container management.

## ✨ Features

- 🎯 **Interactive Volume Selection** - Choose specific volumes to backup
- 🔄 **Auto Container Management** - Automatically stops/starts containers during backup
- 📦 **Remote to Local Backup** - Secure SSH-based volume transfers
- 🗜️ **Smart Compression** - Efficient storage with progress indicators
- 🧹 **Automatic Cleanup** - Maintains configurable backup retention
- 🔍 **Dry Run Mode** - Test operations without making changes
- 🌐 **Multi-Context Support** - Works with multiple Docker contexts

## 🚀 Quick Start

```bash
# Interactive backup with container management
sudo ./backup.sh --host docker.example.com --user ubuntu --key ~/.ssh/id_rsa --interactive

# Backup specific volumes (non-interactive)
sudo ./backup.sh -h 192.168.1.100 -u docker -e "temp_vol,cache_vol" -d /backup/docker-volumes

# Dry run to see what would happen
sudo ./backup.sh --host docker.example.com --dry-run --interactive
```

## ⚠️ Requirements

- **Root privileges required** - Script must be run as root user
- SSH access to remote Docker host
- rsync and Docker installed locally

## 📋 Usage Examples

```bash
# Basic interactive backup
sudo ./backup.sh --host myserver.com --interactive

# Backup with custom SSH key and destination
sudo ./backup.sh -h 192.168.1.100 -k ~/.ssh/docker_key -d /mnt/backups

# Non-interactive with auto-confirm for containers
sudo ./backup.sh --host myserver.com --auto-confirm --non-interactive
```

## 🛠️ Development Status

- ✅ **Backup**: Fully functional with container awareness
- 🚧 **Migration**: Under active development
- 🔄 **Restore**: Planned feature

## 🤖 Credits

- Inspired by [this YouTube tutorial](https://www.youtube.com/watch?v=ZEy8iFbgbPA)
- Most code generated with AI assistance
- Container management features added for production safety

## 📖 Help

Run `./backup.sh --help` for complete usage information and all available options.