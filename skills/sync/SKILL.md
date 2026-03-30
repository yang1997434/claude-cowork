---
name: sync
description: Cross-device Claude Code sync — push/pull configs, plugins, and memory across machines. Use when user types /sync with any subcommand (init, push, pull, status, rollback, devices, config).
---

# Claude Cowork Sync

You are executing the claude-cowork sync skill. This skill syncs Claude Code configuration, plugins, and claude-mem memory across multiple devices via a private GitHub repository.

## Script Location

The core script is at the plugin root:
```
_R="${CLAUDE_PLUGIN_ROOT}"; [ -z "$_R" ] && _R="$HOME/.claude/plugins/marketplaces/claude-cowork/plugin"; "$_R/scripts/cowork.sh"
```

For convenience, define this at the start:
```bash
COWORK_SH="$([ -n \"${CLAUDE_PLUGIN_ROOT:-}\" ] && echo \"$CLAUDE_PLUGIN_ROOT\" || echo \"$HOME/.claude/plugins/marketplaces/claude-cowork/plugin\")/scripts/cowork.sh"
```

If not found there, try: `$HOME/.claude/plugins/cache/claude-cowork/*/scripts/cowork.sh`

## Command Routing

Parse the user's `/sync` command and route to the appropriate handler below:

| User Command | Handler |
|-------------|---------|
| `/sync init` | → Init Flow |
| `/sync push` | → Push Flow |
| `/sync pull` | → Pull Flow |
| `/sync status` | → Status Flow |
| `/sync rollback` | → Rollback Flow |
| `/sync devices` | → Devices Flow |

---

## Init Flow (`/sync init`)

This is an interactive guided setup. Follow these steps exactly:

### Step 0: Check Prerequisites

```bash
# Check required tools
for cmd in gh jq sqlite3 git; do command -v $cmd &>/dev/null || echo "MISSING: $cmd"; done
```

If any are missing, tell the user:
```
Missing: <tool>. Run: brew install <tools>
```
Stop here until they install.

### Step 1: Check GitHub Connectivity

```bash
bash "$COWORK_SH" check-github
```

**If output is `NOT_INSTALLED`:**
> GitHub CLI (gh) is not installed. Run: `brew install gh`

**If output is `NOT_AUTHENTICATED`:**
> GitHub is not connected. Please run `gh auth login` first, then come back to `/sync init`.

**If output is a username** (e.g., `yang1997434`):
> Detected GitHub account: **{username}**

Proceed to Step 2.

### Step 2: Get GitHub Base URL

Ask the user:
> Please provide your GitHub profile URL (e.g., `https://github.com/yang1997434`):

Validate format: must match `https://github.com/<username>`.

### Step 3: Choose Sync Repository

Ask the user:
> Repository name for sync (default: `claude-cowork-sync`):

Then create the repo:
```bash
bash "$COWORK_SH" create-repo "<github_base_url>" "<repo_name>"
```

If the repo already exists, the script handles it by cloning instead.

### Step 4: Register Device

Get device serial automatically:
```bash
ioreg -d2 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/{print $4}'
```

Ask the user:
> Device serial detected: `<serial>`
>
> **Device short name** (used in logs, e.g., `macmini`):
> **Device description** (optional, e.g., "Office Mac mini"):

Then register:
```bash
bash "$COWORK_SH" register-device "<serial>" "<device_name>" "<device_label>" "<username/repo_name>"
```

### Step 5: Setup Auto-Remind Hook

```bash
bash "$COWORK_SH" setup-hooks
```

### Step 6: Confirm

Show the user a summary:
```
🎉 claude-cowork initialized!

  Device:  <name> (<label>)
  Repo:    github.com/<username>/<repo_name>
  Scope:   All configs + plugins + claude-mem
  Remind:  Auto-check on session start

Next steps:
  • Run /sync push to upload current config
  • On your other device: install this plugin → /sync init → choose same repo
```

---

## Push Flow (`/sync push`)

Simply run:
```bash
bash "$COWORK_SH" push
```

The script handles everything: collecting configs, exporting claude-mem, creating snapshots, and pushing to remote. Show the output to the user.

---

## Pull Flow (`/sync pull`)

Simply run:
```bash
bash "$COWORK_SH" pull
```

The script handles: pulling remote, applying configs, reporting missing plugins, importing claude-mem. Show the output to the user.

If the script reports missing plugins, offer to help install them.

---

## Status Flow (`/sync status`)

```bash
bash "$COWORK_SH" status
```

Show the output to the user.

---

## Rollback Flow (`/sync rollback`)

First, show available snapshots:
```bash
bash "$COWORK_SH" rollback
```

Then ask the user which snapshot to restore. Once they choose:
```bash
bash "$COWORK_SH" rollback <number>
```

---

## Devices Flow (`/sync devices`)

```bash
bash "$COWORK_SH" devices
```

Show the output to the user.

---

## Error Handling

- If `cowork.sh` is not found, tell the user the plugin may not be installed correctly
- If `~/.claude-sync/config.json` doesn't exist for push/pull/status, prompt to run `/sync init` first
- If git push/pull fails, suggest checking network or `gh auth status`

## Language

Respond in the same language the user is using (Chinese or English).
