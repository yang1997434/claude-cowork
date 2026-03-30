[English](README.md) | [中文](README.zh-CN.md)

# claude-cowork

Cross-device sync for Claude Code — push and pull your configs, plugins, and memory across machines.

## The Problem

You use Claude Code on multiple devices (e.g., a Mac mini at work and a MacBook at home). When you switch devices:

- Your installed plugins and skills are missing
- Project memory and claude-mem observations don't carry over
- Settings, rules, and HUD configurations need to be set up again

**claude-cowork** solves this by syncing everything through a private GitHub repository.

## What Gets Synced

| Content | Description |
|---------|-------------|
| `settings.json` | Claude Code settings (sensitive keys excluded) |
| `CLAUDE.md` | Global instructions |
| `rules/` | Behavior rules |
| `hud/` | Custom HUD configs |
| Project memories | All `projects/*/memory/` files |
| Plugin manifest | Installed plugin list (auto-reinstall on pull) |
| claude-mem data | Observations, sessions, summaries (deduplicated) |

## Installation

### Prerequisites

```bash
brew install gh jq
gh auth login  # Authenticate with GitHub
```

### Install Plugin

Add to your Claude Code settings or install via marketplace:

```
claude-cowork
```

## Quick Start

### First Device Setup

```
/sync init
```

The guided setup will:
1. Verify GitHub connectivity
2. Create a private sync repository
3. Register your device (auto-detects serial number)
4. Configure auto-remind hooks

Then push your current state:

```
/sync push
```

### Second Device Setup

```
/sync init
```

Choose "I have an existing repo" and enter the same repository URL. Then pull:

```
/sync pull
```

## Commands

| Command | Description |
|---------|-------------|
| `/sync init` | First-time setup (create repo, register device) |
| `/sync push` | Push local changes to remote |
| `/sync pull` | Pull remote changes to local |
| `/sync status` | Show sync status, devices, and history |
| `/sync rollback` | Restore from a history snapshot |
| `/sync devices` | List all registered devices |

## How It Works

### Sync Flow

```
Device A                    GitHub (private repo)                    Device B
   │                              │                                    │
   ├── /sync push ───────────────►│                                    │
   │   • Collect configs          │                                    │
   │   • Export claude-mem        │                                    │
   │   • Snapshot history         │                                    │
   │   • git push                 │                                    │
   │                              │◄──────────────── /sync pull ───────┤
   │                              │   • git pull                       │
   │                              │   • Apply configs                  │
   │                              │   • Import claude-mem (dedup)      │
   │                              │   • Report missing plugins         │
```

### Device Identification

Each device is identified by its hardware serial number (unique, stable) paired with a user-defined friendly name (e.g., `macmini`, `macbook`).

### History & Rollback

Every push creates a snapshot. The 3 most recent snapshots are kept (configurable). Use `/sync rollback` to restore any snapshot.

### claude-mem Deduplication

Observations are deduplicated by `content_hash`, sessions by `memory_session_id`, and summaries by `memory_session_id + prompt_number`. No data is lost or duplicated.

### Auto-Remind

On session start, claude-cowork checks for remote changes and reminds you to pull if your other device has pushed updates.

## Configuration

Local config is stored at `~/.claude-sync/config.json`:

```json
{
  "version": 1,
  "repo": "username/claude-cowork-sync",
  "device": {
    "id": "SERIAL_NUMBER",
    "name": "macmini",
    "label": "Office Mac mini"
  },
  "sync_scope": {
    "global_config": true,
    "hud": true,
    "plugin_manifest": true,
    "project_memory": "all",
    "claude_mem": true
  },
  "auto_remind": true,
  "history_versions": 3
}
```

## Security

- **Private repository**: All sync data is stored in a private GitHub repo
- **No secrets synced**: OAuth tokens, API keys, and credentials are stripped from settings.json
- **Local backups**: Every pull creates a timestamped backup of your local config

## Requirements

- macOS (uses `ioreg` for device serial)
- GitHub CLI (`gh`) authenticated
- `jq` for JSON processing
- `sqlite3` (built into macOS) for claude-mem export/import
- `git`

## License

MIT
