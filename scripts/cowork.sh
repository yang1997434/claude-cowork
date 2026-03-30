#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# claude-cowork — Cross-device Claude Code sync tool
# ============================================================================

SYNC_DIR="$HOME/.claude-sync"
SYNC_CONFIG="$SYNC_DIR/config.json"
SYNC_REPO_DIR="$SYNC_DIR/repo"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_MEM_DIR="$HOME/.claude-mem"
CLAUDE_MEM_DB="$CLAUDE_MEM_DIR/claude-mem.db"

# Git wrapper: skip global hooks for sync repo (not a code project)
sync_git() {
  git -c core.hooksPath=/dev/null "$@"
}

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_ok()   { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_err()  { echo -e "${RED}✗${NC} $1"; }
log_step() { echo -e "${BLUE}→${NC} $1"; }
log_info() { echo -e "${CYAN}ℹ${NC} $1"; }

# ============================================================================
# Utilities
# ============================================================================

check_deps() {
  local missing=()
  for cmd in gh jq sqlite3 git; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Missing dependencies: ${missing[*]}"
    echo "  Run: brew install ${missing[*]}"
    exit 1
  fi
}

get_device_serial() {
  ioreg -d2 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/{print $4}'
}

check_initialized() {
  if [[ ! -f "$SYNC_CONFIG" ]] || [[ ! -d "$SYNC_REPO_DIR/.git" ]]; then
    log_err "claude-cowork not initialized. Run: /sync init"
    exit 1
  fi
}

config_get() {
  jq -r "$1 // empty" "$SYNC_CONFIG" 2>/dev/null
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ts() {
  date +%s
}

# ============================================================================
# Command: check-github
# ============================================================================
cmd_check_github() {
  if ! command -v gh &>/dev/null; then
    echo "NOT_INSTALLED"
    return 0
  fi

  if gh auth status &>/dev/null 2>&1; then
    local user
    user=$(gh api user --jq '.login' 2>/dev/null || echo "")
    if [[ -n "$user" ]]; then
      echo "$user"
      return 0
    fi
  fi

  echo "NOT_AUTHENTICATED"
  return 0
}

# ============================================================================
# Command: create-repo
# ============================================================================
cmd_create_repo() {
  local github_base="$1"  # e.g., https://github.com/yang1997434
  local repo_name="$2"    # e.g., Maruiao-claude-cowork

  # Extract username from base URL
  local username
  username=$(echo "$github_base" | sed 's|.*github.com/||' | sed 's|/$||')

  mkdir -p "$SYNC_DIR"

  # Create private repo
  log_step "Creating private repo: $username/$repo_name ..."
  gh repo create "$username/$repo_name" --private --description "Claude Code cross-device sync" 2>/dev/null || {
    # Repo might already exist
    log_warn "Repo may already exist, attempting to clone..."
  }

  # Clone to local
  if [[ -d "$SYNC_REPO_DIR/.git" ]]; then
    log_warn "Local repo already exists at $SYNC_REPO_DIR"
  else
    git clone "https://github.com/$username/$repo_name.git" "$SYNC_REPO_DIR" 2>/dev/null || {
      # If clone fails (empty repo), init locally
      mkdir -p "$SYNC_REPO_DIR"
      cd "$SYNC_REPO_DIR"
      git init
      git remote add origin "https://github.com/$username/$repo_name.git"
      git checkout -b main
    }
  fi

  # Initialize repo structure
  mkdir -p "$SYNC_REPO_DIR/current/config/rules"
  mkdir -p "$SYNC_REPO_DIR/current/config/hud"
  mkdir -p "$SYNC_REPO_DIR/current/config/projects"
  mkdir -p "$SYNC_REPO_DIR/current/plugins"
  mkdir -p "$SYNC_REPO_DIR/current/claude-mem"
  mkdir -p "$SYNC_REPO_DIR/history"

  # Create .gitignore
  cat > "$SYNC_REPO_DIR/.gitignore" << 'EOF'
.DS_Store
*.swp
*.tmp
EOF

  # Initialize devices.json if not exists
  [[ -f "$SYNC_REPO_DIR/devices.json" ]] || echo '{}' > "$SYNC_REPO_DIR/devices.json"

  # Initial commit
  cd "$SYNC_REPO_DIR"
  sync_git add -A
  if ! sync_git diff --cached --quiet 2>/dev/null; then
    sync_git commit -m "init: claude-cowork sync repo"
    sync_git push -u origin main 2>/dev/null || sync_git push --set-upstream origin main
  fi

  log_ok "Repo ready: https://github.com/$username/$repo_name"
  echo "$username/$repo_name"
}

# ============================================================================
# Command: register-device
# ============================================================================
cmd_register_device() {
  local device_id="$1"
  local device_name="$2"
  local device_label="$3"
  local repo_url="$4"

  mkdir -p "$SYNC_DIR"

  # Save local config
  jq -n \
    --arg repo "$repo_url" \
    --arg did "$device_id" \
    --arg dname "$device_name" \
    --arg dlabel "$device_label" \
    --arg reg "$(now_iso)" \
    '{
      version: 1,
      repo: $repo,
      device: { id: $did, name: $dname, label: $dlabel, registered_at: $reg },
      sync_scope: { global_config: true, hud: true, plugin_manifest: true, project_memory: "all", claude_mem: true },
      auto_remind: true,
      history_versions: 3
    }' > "$SYNC_CONFIG"

  # Update devices.json in repo
  local devices_file="$SYNC_REPO_DIR/devices.json"
  local now
  now=$(now_iso)

  if [[ -f "$devices_file" ]]; then
    jq --arg id "$device_id" \
       --arg name "$device_name" \
       --arg label "$device_label" \
       --arg reg "$now" \
      '.[$id] = { name: $name, label: $label, registered_at: $reg, last_sync: null }' \
      "$devices_file" > "$devices_file.tmp"
    mv "$devices_file.tmp" "$devices_file"
  else
    jq -n --arg id "$device_id" \
          --arg name "$device_name" \
          --arg label "$device_label" \
          --arg reg "$now" \
      '{ ($id): { name: $name, label: $label, registered_at: $reg, last_sync: null } }' \
      > "$devices_file"
  fi

  cd "$SYNC_REPO_DIR"
  sync_git add devices.json
  sync_git commit -m "device: register $device_name ($device_id)"
  sync_git push

  log_ok "Device registered: $device_name ($device_label)"
}

# ============================================================================
# Command: push
# ============================================================================
cmd_push() {
  check_initialized
  check_deps

  local device_name
  device_name=$(config_get '.device.name')
  local timestamp
  timestamp=$(date +%Y-%m-%dT%H:%M:%S)

  log_step "Collecting config files..."
  sync_config_to_repo

  log_step "Generating plugin manifest..."
  generate_plugin_manifest

  log_step "Exporting claude-mem data..."
  export_claude_mem

  log_step "Creating history snapshot..."
  create_snapshot "$device_name" "$timestamp"

  # Update last_sync before commit so it's included in the same push
  update_last_sync_local "$device_name"

  cd "$SYNC_REPO_DIR"
  sync_git add -A

  # Check if there are changes
  if sync_git diff --cached --quiet 2>/dev/null; then
    log_ok "No changes to sync"
    return 0
  fi

  local stat
  stat=$(sync_git diff --cached --stat | tail -1)
  sync_git commit -m "sync: $device_name @ $timestamp"
  sync_git push

  # Periodic git gc: run every 20 pushes to control repo bloat
  local gc_counter_file="$SYNC_DIR/.gc-counter"
  local gc_count=0
  [[ -f "$gc_counter_file" ]] && gc_count=$(cat "$gc_counter_file")
  gc_count=$((gc_count + 1))
  if [[ $gc_count -ge 20 ]]; then
    sync_git gc --aggressive --prune=now --quiet 2>/dev/null && log_info "Git gc: repo compacted"
    gc_count=0
  fi
  echo "$gc_count" > "$gc_counter_file"

  echo ""
  log_ok "Push complete ($device_name → remote)"
  echo "  $stat"
}

sync_config_to_repo() {
  local target="$SYNC_REPO_DIR/current/config"

  # settings.json (strip sensitive fields)
  if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
    jq 'del(.oauthToken, .credentials, .apiKey)' "$CLAUDE_DIR/settings.json" > "$target/settings.json"
  fi

  # CLAUDE.md
  [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && cp "$CLAUDE_DIR/CLAUDE.md" "$target/"

  # rules/
  if [[ -d "$CLAUDE_DIR/rules" ]]; then
    mkdir -p "$target/rules"
    rsync -a --delete "$CLAUDE_DIR/rules/" "$target/rules/"
  fi

  # hud/
  if [[ -d "$CLAUDE_DIR/hud" ]]; then
    mkdir -p "$target/hud"
    rsync -a --delete "$CLAUDE_DIR/hud/" "$target/hud/"
  fi

  # project memories (only memory/ subdirs, skip everything else)
  if [[ -d "$CLAUDE_DIR/projects" ]]; then
    find "$CLAUDE_DIR/projects" -path "*/memory/*" -type f 2>/dev/null | while read -r f; do
      local rel="${f#$CLAUDE_DIR/}"
      mkdir -p "$target/$(dirname "$rel")"
      cp "$f" "$target/$rel"
    done
  fi
}

generate_plugin_manifest() {
  local manifest="$SYNC_REPO_DIR/current/plugins/manifest.json"
  mkdir -p "$(dirname "$manifest")"

  local settings="$CLAUDE_DIR/settings.json"

  # Start with enabled plugins list
  local enabled_json="[]"
  if [[ -f "$settings" ]]; then
    enabled_json=$(jq '.enabledPlugins // []' "$settings" 2>/dev/null || echo "[]")
  fi

  # Collect installed plugin info from cache
  local plugins_arr="[]"
  if [[ -d "$CLAUDE_DIR/plugins/cache" ]]; then
    for pdir in "$CLAUDE_DIR/plugins/cache"/*/; do
      [[ -d "$pdir" ]] || continue
      local pname
      pname=$(basename "$pdir")
      # Skip temporary worktree plugin directories
      [[ "$pname" == temp_git_* ]] && continue
      # Find plugin.json for version info
      local pjson
      pjson=$(find "$pdir" -name "plugin.json" -path "*/.claude-plugin/*" -print -quit 2>/dev/null)
      if [[ -n "$pjson" ]]; then
        local ver
        ver=$(jq -r '.version // "unknown"' "$pjson")
        local desc
        desc=$(jq -r '.description // ""' "$pjson")
        local repo
        repo=$(jq -r '.repository // ""' "$pjson")
        plugins_arr=$(echo "$plugins_arr" | jq --arg n "$pname" --arg v "$ver" --arg d "$desc" --arg r "$repo" \
          '. + [{ name: $n, version: $v, description: $d, repository: $r }]')
      else
        plugins_arr=$(echo "$plugins_arr" | jq --arg n "$pname" \
          '. + [{ name: $n, version: "unknown", description: "", repository: "" }]')
      fi
    done
  fi

  # Also check marketplaces
  if [[ -d "$CLAUDE_DIR/plugins/marketplaces" ]]; then
    for pdir in "$CLAUDE_DIR/plugins/marketplaces"/*/plugin/; do
      [[ -d "$pdir" ]] || continue
      local pjson="$pdir/.claude-plugin/plugin.json"
      if [[ -f "$pjson" ]]; then
        local pname ver desc repo
        pname=$(jq -r '.name // "unknown"' "$pjson")
        ver=$(jq -r '.version // "unknown"' "$pjson")
        desc=$(jq -r '.description // ""' "$pjson")
        repo=$(jq -r '.repository // ""' "$pjson")
        plugins_arr=$(echo "$plugins_arr" | jq --arg n "$pname" --arg v "$ver" --arg d "$desc" --arg r "$repo" \
          '. + [{ name: $n, version: $v, description: $d, repository: $r }]')
      fi
    done
  fi

  jq -n --argjson enabled "$enabled_json" --argjson plugins "$plugins_arr" \
    '{ enabled_plugins: $enabled, installed_plugins: $plugins, updated_at: (now | todate) }' \
    > "$manifest"

  local count
  count=$(echo "$plugins_arr" | jq 'length')
  log_ok "Plugin manifest: $count plugins"
}

export_claude_mem() {
  local target="$SYNC_REPO_DIR/current/claude-mem"
  mkdir -p "$target"

  if [[ ! -f "$CLAUDE_MEM_DB" ]]; then
    log_warn "claude-mem database not found, skipping"
    return 0
  fi

  # Export observations
  sqlite3 "$CLAUDE_MEM_DB" "SELECT json_group_array(json_object(
    'id', id,
    'memory_session_id', memory_session_id,
    'project', project,
    'type', type,
    'title', title,
    'subtitle', subtitle,
    'facts', facts,
    'narrative', narrative,
    'concepts', concepts,
    'files_read', files_read,
    'files_modified', files_modified,
    'prompt_number', prompt_number,
    'discovery_tokens', discovery_tokens,
    'created_at', created_at,
    'created_at_epoch', created_at_epoch,
    'content_hash', content_hash
  )) FROM observations ORDER BY id;" 2>/dev/null | jq -c '.[]' > "$target/observations.jsonl" || true

  # Export sessions
  sqlite3 "$CLAUDE_MEM_DB" "SELECT json_group_array(json_object(
    'id', id,
    'content_session_id', content_session_id,
    'memory_session_id', memory_session_id,
    'project', project,
    'user_prompt', user_prompt,
    'started_at', started_at,
    'started_at_epoch', started_at_epoch,
    'completed_at', completed_at,
    'completed_at_epoch', completed_at_epoch,
    'status', status,
    'prompt_counter', prompt_counter,
    'custom_title', custom_title
  )) FROM sdk_sessions ORDER BY id;" 2>/dev/null | jq -c '.[]' > "$target/sessions.jsonl" || true

  # Export summaries
  sqlite3 "$CLAUDE_MEM_DB" "SELECT json_group_array(json_object(
    'memory_session_id', memory_session_id,
    'project', project,
    'request', request,
    'investigated', investigated,
    'learned', learned,
    'completed', completed,
    'next_steps', next_steps,
    'files_read', files_read,
    'files_edited', files_edited,
    'notes', notes,
    'prompt_number', prompt_number,
    'discovery_tokens', discovery_tokens,
    'created_at', created_at,
    'created_at_epoch', created_at_epoch
  )) FROM session_summaries ORDER BY created_at_epoch;" 2>/dev/null | jq -c '.[]' > "$target/summaries.jsonl" || true

  local obs_count=0 sess_count=0 summ_count=0
  [[ -f "$target/observations.jsonl" ]] && obs_count=$(wc -l < "$target/observations.jsonl" | tr -d ' ')
  [[ -f "$target/sessions.jsonl" ]] && sess_count=$(wc -l < "$target/sessions.jsonl" | tr -d ' ')
  [[ -f "$target/summaries.jsonl" ]] && summ_count=$(wc -l < "$target/summaries.jsonl" | tr -d ' ')

  log_ok "claude-mem export: $obs_count observations, $sess_count sessions, $summ_count summaries"
}

create_snapshot() {
  local device_name="$1" timestamp="$2"
  local history_dir="$SYNC_REPO_DIR/history"
  local snapshot_name="${timestamp}_${device_name}"

  mkdir -p "$history_dir"

  # Only snapshot if current/ exists and has content
  if [[ -d "$SYNC_REPO_DIR/current" ]] && [[ -n "$(ls -A "$SYNC_REPO_DIR/current" 2>/dev/null)" ]]; then
    cp -R "$SYNC_REPO_DIR/current" "$history_dir/$snapshot_name"
  fi

  # Rotate: keep only N versions
  local max_versions
  max_versions=$(config_get '.history_versions' || echo "3")
  [[ -z "$max_versions" ]] && max_versions=3

  local snapshots=()
  while IFS= read -r d; do
    [[ -d "$d" ]] && snapshots+=("$d")
  done < <(ls -1d "$history_dir"/*/ 2>/dev/null | sort)

  local count=${#snapshots[@]}
  if [[ "$count" -gt "$max_versions" ]]; then
    local to_remove=$((count - max_versions))
    for ((i = 0; i < to_remove; i++)); do
      rm -rf "${snapshots[$i]}"
    done
    log_info "Rotated history: removed $to_remove old snapshot(s)"
  fi
}

# Update last_sync in devices.json (file only, no commit/push)
update_last_sync_local() {
  local device_name="$1"
  local devices_file="$SYNC_REPO_DIR/devices.json"
  local now
  now=$(now_iso)

  if [[ -f "$devices_file" ]]; then
    local device_id
    device_id=$(config_get '.device.id')
    jq --arg id "$device_id" --arg ts "$now" \
      '.[$id].last_sync = $ts' "$devices_file" > "$devices_file.tmp"
    mv "$devices_file.tmp" "$devices_file"
  fi
}

# Update last_sync and commit+push (used by pull)
update_last_sync() {
  update_last_sync_local "$1"
  cd "$SYNC_REPO_DIR"
  sync_git add devices.json
  sync_git commit -m "sync: update last_sync for $1" --allow-empty 2>/dev/null || true
  sync_git push 2>/dev/null || true
}

# ============================================================================
# Command: pull
# ============================================================================
cmd_pull() {
  check_initialized
  check_deps

  local device_name
  device_name=$(config_get '.device.name')

  log_step "Pulling remote changes..."
  cd "$SYNC_REPO_DIR"
  git fetch origin
  local local_head remote_head
  local_head=$(git rev-parse HEAD 2>/dev/null || echo "none")
  remote_head=$(git rev-parse origin/main 2>/dev/null || echo "none")

  if [[ "$local_head" == "$remote_head" ]]; then
    log_ok "Already up to date"
    return 0
  fi

  sync_git pull --rebase 2>/dev/null || sync_git pull

  log_step "Applying config files..."
  apply_config_from_repo

  log_step "Checking plugin manifest..."
  check_and_report_plugins

  log_step "Importing claude-mem data..."
  import_claude_mem

  update_last_sync "$device_name"

  echo ""
  log_ok "Pull complete (remote → $device_name)"
}

apply_config_from_repo() {
  local source="$SYNC_REPO_DIR/current/config"
  [[ -d "$source" ]] || { log_warn "No config files in remote"; return 0; }

  # Backup current local config
  local backup_dir="$SYNC_DIR/backups/$(date +%Y%m%d%H%M%S)"
  mkdir -p "$backup_dir"

  # settings.json
  if [[ -f "$source/settings.json" ]]; then
    [[ -f "$CLAUDE_DIR/settings.json" ]] && cp "$CLAUDE_DIR/settings.json" "$backup_dir/"
    # Merge: take remote, but preserve local-only keys (oauthToken, credentials)
    if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
      local local_sensitive
      local_sensitive=$(jq '{ oauthToken, credentials, apiKey } | with_entries(select(.value != null))' "$CLAUDE_DIR/settings.json" 2>/dev/null || echo '{}')
      jq -s '.[0] * .[1]' "$source/settings.json" <(echo "$local_sensitive") > "$CLAUDE_DIR/settings.json"
    else
      cp "$source/settings.json" "$CLAUDE_DIR/settings.json"
    fi
  fi

  # CLAUDE.md
  if [[ -f "$source/CLAUDE.md" ]]; then
    [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && cp "$CLAUDE_DIR/CLAUDE.md" "$backup_dir/"
    cp "$source/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  fi

  # rules/
  if [[ -d "$source/rules" ]]; then
    [[ -d "$CLAUDE_DIR/rules" ]] && cp -R "$CLAUDE_DIR/rules" "$backup_dir/rules"
    mkdir -p "$CLAUDE_DIR/rules"
    rsync -a --delete "$source/rules/" "$CLAUDE_DIR/rules/"
  fi

  # hud/
  if [[ -d "$source/hud" ]]; then
    [[ -d "$CLAUDE_DIR/hud" ]] && cp -R "$CLAUDE_DIR/hud" "$backup_dir/hud"
    mkdir -p "$CLAUDE_DIR/hud"
    rsync -a --delete "$source/hud/" "$CLAUDE_DIR/hud/"
  fi

  # project memories
  if [[ -d "$source/projects" ]]; then
    find "$source/projects" -type f 2>/dev/null | while read -r f; do
      local rel="${f#$source/}"
      mkdir -p "$CLAUDE_DIR/$(dirname "$rel")"
      cp "$f" "$CLAUDE_DIR/$rel"
    done
  fi

  log_ok "Config applied (backup: $backup_dir)"
}

check_and_report_plugins() {
  local manifest="$SYNC_REPO_DIR/current/plugins/manifest.json"
  [[ -f "$manifest" ]] || return 0

  local missing=()
  local installed=()

  while IFS= read -r plugin_json; do
    local pname prepo
    pname=$(echo "$plugin_json" | jq -r '.name')
    prepo=$(echo "$plugin_json" | jq -r '.repository // ""')

    # Check if installed locally
    if [[ -d "$CLAUDE_DIR/plugins/cache/$pname" ]] || \
       find "$CLAUDE_DIR/plugins/marketplaces" -name "plugin.json" -exec grep -l "\"$pname\"" {} \; 2>/dev/null | grep -q .; then
      installed+=("$pname")
    else
      missing+=("$pname|$prepo")
    fi
  done < <(jq -c '.installed_plugins[]?' "$manifest" 2>/dev/null)

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Missing plugins (install manually):"
    for entry in "${missing[@]}"; do
      local name="${entry%%|*}"
      local repo="${entry##*|}"
      if [[ -n "$repo" ]]; then
        echo "  ○ $name → $repo"
      else
        echo "  ○ $name"
      fi
    done
  fi

  if [[ ${#installed[@]} -gt 0 ]]; then
    log_ok "Plugins in sync: ${#installed[@]} installed"
  fi
}

import_claude_mem() {
  local source="$SYNC_REPO_DIR/current/claude-mem"
  [[ -d "$source" ]] || { log_warn "No claude-mem data in remote"; return 0; }
  [[ -f "$CLAUDE_MEM_DB" ]] || { log_warn "Local claude-mem database not found, skipping"; return 0; }
  [[ -f "$source/observations.jsonl" ]] || { log_info "No observations to import"; return 0; }

  # Use Python for safe SQLite import with proper escaping
  python3 << 'PYEOF'
import sqlite3
import json
import sys
import os

source_dir = os.path.expanduser("~/.claude-sync/repo/current/claude-mem")
db_path = os.path.expanduser("~/.claude-mem/claude-mem.db")

if not os.path.exists(db_path):
    sys.exit(0)

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

imported = 0
skipped = 0

# Import observations (dedup by memory_session_id + created_at_epoch)
obs_file = os.path.join(source_dir, "observations.jsonl")
if os.path.exists(obs_file):
    # Build set of existing observation keys for dedup
    existing_obs = set()
    try:
        for row in cursor.execute(
            "SELECT memory_session_id, created_at_epoch FROM observations"
        ):
            existing_obs.add((row[0] or '', row[1] or 0))
    except:
        pass

    with open(obs_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            dedup_key = (
                obj.get('memory_session_id', ''),
                obj.get('created_at_epoch', 0)
            )
            if dedup_key in existing_obs:
                skipped += 1
                continue

            try:
                cursor.execute("""
                    INSERT INTO observations
                    (memory_session_id, project, type, title, subtitle, facts, narrative,
                     concepts, files_read, files_modified, prompt_number, discovery_tokens,
                     created_at, created_at_epoch, content_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    obj.get('memory_session_id', ''),
                    obj.get('project', ''),
                    obj.get('type', ''),
                    obj.get('title', ''),
                    obj.get('subtitle', ''),
                    obj.get('facts', ''),
                    obj.get('narrative', ''),
                    obj.get('concepts', ''),
                    obj.get('files_read', ''),
                    obj.get('files_modified', ''),
                    obj.get('prompt_number', 0),
                    obj.get('discovery_tokens', 0),
                    obj.get('created_at', ''),
                    obj.get('created_at_epoch', 0),
                    obj.get('content_hash', '')
                ))
                imported += 1
                existing_obs.add(dedup_key)
            except sqlite3.IntegrityError:
                skipped += 1
            except Exception as e:
                skipped += 1

# Import sessions (dedup by memory_session_id)
sess_file = os.path.join(source_dir, "sessions.jsonl")
sess_imported = 0
sess_skipped = 0
if os.path.exists(sess_file):
    existing_sessions = set()
    try:
        for row in cursor.execute("SELECT memory_session_id FROM sdk_sessions WHERE memory_session_id IS NOT NULL"):
            existing_sessions.add(row[0])
    except:
        pass

    with open(sess_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msid = obj.get('memory_session_id', '')
            if not msid or msid in existing_sessions:
                sess_skipped += 1
                continue

            try:
                cursor.execute("""
                    INSERT INTO sdk_sessions
                    (content_session_id, memory_session_id, project, user_prompt,
                     started_at, started_at_epoch, completed_at, completed_at_epoch,
                     status, prompt_counter, custom_title)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    obj.get('content_session_id', ''),
                    msid,
                    obj.get('project', ''),
                    obj.get('user_prompt', ''),
                    obj.get('started_at', ''),
                    obj.get('started_at_epoch', 0),
                    obj.get('completed_at', ''),
                    obj.get('completed_at_epoch', 0),
                    obj.get('status', ''),
                    obj.get('prompt_counter', 0),
                    obj.get('custom_title', '')
                ))
                sess_imported += 1
                existing_sessions.add(msid)
            except:
                sess_skipped += 1

# Import summaries (dedup by memory_session_id + prompt_number)
summ_file = os.path.join(source_dir, "summaries.jsonl")
summ_imported = 0
summ_skipped = 0
if os.path.exists(summ_file):
    existing_summ = set()
    try:
        for row in cursor.execute("SELECT memory_session_id, prompt_number FROM session_summaries"):
            existing_summ.add((row[0], row[1]))
    except:
        pass

    with open(summ_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            key = (obj.get('memory_session_id', ''), obj.get('prompt_number', 0))
            if key in existing_summ:
                summ_skipped += 1
                continue

            try:
                cursor.execute("""
                    INSERT INTO session_summaries
                    (memory_session_id, project, request, investigated, learned,
                     completed, next_steps, files_read, files_edited, notes,
                     prompt_number, discovery_tokens, created_at, created_at_epoch)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    obj.get('memory_session_id', ''),
                    obj.get('project', ''),
                    obj.get('request', ''),
                    obj.get('investigated', ''),
                    obj.get('learned', ''),
                    obj.get('completed', ''),
                    obj.get('next_steps', ''),
                    obj.get('files_read', ''),
                    obj.get('files_edited', ''),
                    obj.get('notes', ''),
                    obj.get('prompt_number', 0),
                    obj.get('discovery_tokens', 0),
                    obj.get('created_at', ''),
                    obj.get('created_at_epoch', 0)
                ))
                summ_imported += 1
                existing_summ.add(key)
            except:
                summ_skipped += 1

conn.commit()
conn.close()

print(f"observations: +{imported} new, {skipped} existing")
print(f"sessions: +{sess_imported} new, {sess_skipped} existing")
print(f"summaries: +{summ_imported} new, {summ_skipped} existing")
PYEOF

  local result=$?
  if [[ $result -eq 0 ]]; then
    log_ok "claude-mem import complete"
  else
    log_warn "claude-mem import encountered issues"
  fi
}

# ============================================================================
# Command: status
# ============================================================================
cmd_status() {
  check_initialized

  local device_name device_id repo
  device_name=$(config_get '.device.name')
  device_id=$(config_get '.device.id')
  repo=$(config_get '.repo')

  echo -e "${BOLD}claude-cowork status${NC}"
  echo ""
  echo -e "  Device:  ${CYAN}$device_name${NC} ($device_id)"
  echo -e "  Repo:    $repo"
  echo ""

  # Show all devices
  echo -e "${BOLD}Registered devices:${NC}"
  local devices_file="$SYNC_REPO_DIR/devices.json"
  if [[ -f "$devices_file" ]]; then
    jq -r 'to_entries[] | "  \(if .key == "'"$device_id"'" then "● " else "○ " end)\(.value.name) — \(.value.label) (last sync: \(.value.last_sync // "never"))"' "$devices_file"
  fi
  echo ""

  # Check remote status
  cd "$SYNC_REPO_DIR"
  git fetch origin 2>/dev/null || true
  local local_head remote_head
  local_head=$(git rev-parse HEAD 2>/dev/null || echo "none")
  remote_head=$(git rev-parse origin/main 2>/dev/null || echo "none")

  if [[ "$local_head" == "$remote_head" ]]; then
    echo -e "  Sync:    ${GREEN}Up to date${NC}"
  elif git merge-base --is-ancestor "$local_head" "$remote_head" 2>/dev/null; then
    local behind
    behind=$(git rev-list --count HEAD..origin/main)
    echo -e "  Sync:    ${YELLOW}$behind commit(s) behind remote — run /sync pull${NC}"
  elif git merge-base --is-ancestor "$remote_head" "$local_head" 2>/dev/null; then
    local ahead
    ahead=$(git rev-list --count origin/main..HEAD)
    echo -e "  Sync:    ${YELLOW}$ahead commit(s) ahead — run /sync push${NC}"
  else
    echo -e "  Sync:    ${RED}Diverged — run /sync pull then /sync push${NC}"
  fi

  # Show history snapshots
  local history_dir="$SYNC_REPO_DIR/history"
  if [[ -d "$history_dir" ]] && [[ -n "$(ls -A "$history_dir" 2>/dev/null)" ]]; then
    echo ""
    echo -e "${BOLD}History snapshots:${NC}"
    ls -1d "$history_dir"/*/ 2>/dev/null | sort -r | while read -r snap; do
      local name
      name=$(basename "$snap")
      echo "  📦 $name"
    done
  fi
}

# ============================================================================
# Command: rollback
# ============================================================================
cmd_rollback() {
  check_initialized

  local history_dir="$SYNC_REPO_DIR/history"
  if [[ ! -d "$history_dir" ]] || [[ -z "$(ls -A "$history_dir" 2>/dev/null)" ]]; then
    log_err "No history snapshots available"
    exit 1
  fi

  # List available snapshots
  echo -e "${BOLD}Available snapshots:${NC}"
  local i=1
  local snapshots=()
  while IFS= read -r snap; do
    snapshots+=("$snap")
    local name
    name=$(basename "$snap")
    echo "  [$i] $name"
    ((i++))
  done < <(ls -1d "$history_dir"/*/ 2>/dev/null | sort -r)

  # If a number was passed as argument, use it
  local choice="${1:-}"
  if [[ -z "$choice" ]]; then
    echo ""
    echo "Pass snapshot number as argument: /sync rollback <number>"
    return 0
  fi

  if [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#snapshots[@]} ]]; then
    log_err "Invalid choice: $choice"
    exit 1
  fi

  local selected="${snapshots[$((choice - 1))]}"
  local snap_name
  snap_name=$(basename "$selected")

  log_step "Rolling back to: $snap_name"

  # Replace current with snapshot
  rm -rf "$SYNC_REPO_DIR/current"
  cp -R "$selected" "$SYNC_REPO_DIR/current"

  # Apply to local
  apply_config_from_repo
  import_claude_mem

  # Commit the rollback
  cd "$SYNC_REPO_DIR"
  sync_git add -A
  if ! sync_git diff --cached --quiet 2>/dev/null; then
    local device_name
    device_name=$(config_get '.device.name')
    sync_git commit -m "rollback: $device_name → $snap_name"
    sync_git push
  fi

  log_ok "Rolled back to $snap_name"
}

# ============================================================================
# Command: devices
# ============================================================================
cmd_devices() {
  check_initialized

  local devices_file="$SYNC_REPO_DIR/devices.json"
  local device_id
  device_id=$(config_get '.device.id')

  echo -e "${BOLD}Registered devices:${NC}"
  echo ""

  if [[ -f "$devices_file" ]]; then
    jq -r 'to_entries[] | . as $e |
      "  \(if $e.key == "'"$device_id"'" then "● (this)" else "○       " end) \($e.value.name)\n    Label: \($e.value.label)\n    ID: \($e.key)\n    Registered: \($e.value.registered_at // "unknown")\n    Last sync: \($e.value.last_sync // "never")\n"' \
      "$devices_file"
  else
    echo "  No devices registered"
  fi
}

# ============================================================================
# Command: check-remote (for auto-remind hook)
# ============================================================================
cmd_check_remote() {
  # Silent check — only output if there are remote changes
  [[ -f "$SYNC_CONFIG" ]] || exit 0
  [[ -d "$SYNC_REPO_DIR/.git" ]] || exit 0

  cd "$SYNC_REPO_DIR"
  git fetch origin --quiet 2>/dev/null || exit 0

  local local_head remote_head
  local_head=$(git rev-parse HEAD 2>/dev/null || echo "none")
  remote_head=$(git rev-parse origin/main 2>/dev/null || echo "none")

  if [[ "$local_head" != "$remote_head" ]] && \
     git merge-base --is-ancestor "$local_head" "$remote_head" 2>/dev/null; then
    local behind device_info
    behind=$(git rev-list --count HEAD..origin/main)

    # Find which device pushed last
    device_info=$(git log origin/main -1 --pretty=format:"%s" 2>/dev/null | sed 's/sync: //' | cut -d@ -f1 | xargs)

    echo "claude-cowork: ${behind} new sync(s) from ${device_info}— run /sync pull"
  fi
}

# ============================================================================
# Command: setup-hooks
# ============================================================================
cmd_setup_hooks() {
  # Install the auto-remind hook into user's Claude Code settings
  local settings="$CLAUDE_DIR/settings.json"

  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
  fi

  # Get the plugin root (where this script lives)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Copy auto-remind script to a stable location
  local remind_script="$SYNC_DIR/scripts/auto-remind.sh"
  mkdir -p "$SYNC_DIR/scripts"
  cat > "$remind_script" << 'REMIND_EOF'
#!/usr/bin/env bash
SYNC_DIR="$HOME/.claude-sync"
SYNC_CONFIG="$SYNC_DIR/config.json"
SYNC_REPO_DIR="$SYNC_DIR/repo"

[[ -f "$SYNC_CONFIG" ]] || exit 0
[[ -d "$SYNC_REPO_DIR/.git" ]] || exit 0

# Rate limit: once per hour
CHECK_FILE="$SYNC_DIR/.last-remote-check"
INTERVAL=3600

if [[ -f "$CHECK_FILE" ]]; then
  LAST=$(cat "$CHECK_FILE")
  NOW=$(date +%s)
  [[ $((NOW - LAST)) -lt $INTERVAL ]] && exit 0
fi

date +%s > "$CHECK_FILE"

cd "$SYNC_REPO_DIR"
git fetch origin --quiet 2>/dev/null || exit 0

LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "none")
REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "none")

if [[ "$LOCAL" != "$REMOTE" ]] && \
   git merge-base --is-ancestor "$LOCAL" "$REMOTE" 2>/dev/null; then
  BEHIND=$(git rev-list --count HEAD..origin/main)
  DEVICE=$(git log origin/main -1 --pretty=format:"%s" 2>/dev/null | sed 's/sync: //' | cut -d@ -f1 | xargs)
  echo "⚠ claude-cowork: ${BEHIND} new sync(s) from ${DEVICE}— run /sync pull"
fi
REMIND_EOF
  chmod +x "$remind_script"

  log_ok "Auto-remind hook installed at $remind_script"
}

# ============================================================================
# Main
# ============================================================================
usage() {
  echo -e "${BOLD}claude-cowork${NC} — Cross-device Claude Code sync"
  echo ""
  echo "Commands:"
  echo "  check-github          Check GitHub CLI authentication"
  echo "  create-repo <base> <name>  Create sync repository"
  echo "  register-device <id> <name> <label> <repo>  Register this device"
  echo "  push                  Push local changes to remote"
  echo "  pull                  Pull remote changes to local"
  echo "  status                Show sync status"
  echo "  rollback [n]          Rollback to history snapshot"
  echo "  devices               List registered devices"
  echo "  check-remote          Check for remote changes (auto-remind)"
  echo "  setup-hooks           Install auto-remind hook"
  exit 0
}

case "${1:-}" in
  check-github)    cmd_check_github ;;
  create-repo)     shift; cmd_create_repo "$@" ;;
  register-device) shift; cmd_register_device "$@" ;;
  push)            cmd_push ;;
  pull)            cmd_pull ;;
  status)          cmd_status ;;
  rollback)        shift; cmd_rollback "$@" ;;
  devices)         cmd_devices ;;
  check-remote)    cmd_check_remote ;;
  setup-hooks)     cmd_setup_hooks ;;
  *)               usage ;;
esac
