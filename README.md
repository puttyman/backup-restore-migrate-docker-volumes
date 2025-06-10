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

## 📋 Usage Examples

```bash
# Basic interactive backup
./backup.sh --host myserver.com

# Backup with custom SSH key and destination
./backup.sh -h 192.168.1.100 -k ~/.ssh/id_rsa_public_key
```

## ⚠️ Requirements

- **Host root privileges required** - Only tested with a host root user.
- SSH access to remote Docker host
- **Rsync** installed locally

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