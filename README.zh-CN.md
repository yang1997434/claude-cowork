[English](README.md) | [中文](README.zh-CN.md)

# claude-cowork

Claude Code 跨设备同步工具 — 在多台电脑之间同步配置、插件和记忆。

## 解决什么问题

你在多台设备上使用 Claude Code（比如公司的 Mac mini 和家里的 MacBook）。切换设备时：

- 安装的插件和 skills 不见了
- 项目记忆和 claude-mem 的工作记录无法延续
- 设置、规则、HUD 配置需要重新配置

**claude-cowork** 通过一个私有 GitHub 仓库同步所有内容，解决这个问题。

## 同步内容

| 内容 | 说明 |
|------|------|
| `settings.json` | Claude Code 设置（敏感字段已排除） |
| `CLAUDE.md` | 全局指令 |
| `rules/` | 行为规则 |
| `hud/` | 自定义 HUD 配置 |
| 项目记忆 | 所有 `projects/*/memory/` 文件 |
| 插件清单 | 已安装插件列表（pull 时提示安装缺失的） |
| claude-mem 数据 | observations、sessions、summaries（自动去重） |

## 安装

### 前置要求

```bash
brew install gh jq
gh auth login  # 连接 GitHub 账号
```

### 安装插件

在 Claude Code 中依次运行：

```bash
# 第 1 步：添加插件源
/plugin marketplace add yang1997434/claude-cowork

# 第 2 步：安装插件
/plugin install claude-cowork@claude-cowork
```

## 快速开始

### 第一台设备

```
/sync init
```

引导流程会：
1. 检查 GitHub 连接状态
2. 创建私有同步仓库
3. 注册设备（自动获取序列号）
4. 配置自动提醒

然后推送当前状态：

```
/sync push
```

### 第二台设备

```
/sync init
```

选择「我有现成的仓库」，输入同一个仓库地址。然后拉取：

```
/sync pull
```

## 命令列表

| 命令 | 说明 |
|------|------|
| `/sync init` | 首次设置（创建仓库、注册设备） |
| `/sync push` | 推送本地变更到远程 |
| `/sync pull` | 拉取远程变更到本地 |
| `/sync status` | 查看同步状态、设备列表、历史快照 |
| `/sync rollback` | 回滚到历史快照 |
| `/sync devices` | 查看所有已注册设备 |

## 工作原理

### 同步流程

```
设备 A                       GitHub（私有仓库）                      设备 B
  │                              │                                    │
  ├── /sync push ───────────────►│                                    │
  │   • 收集配置文件              │                                    │
  │   • 导出 claude-mem           │                                    │
  │   • 创建历史快照              │                                    │
  │   • git push                 │                                    │
  │                              │◄──────────────── /sync pull ───────┤
  │                              │   • git pull                       │
  │                              │   • 应用配置文件                     │
  │                              │   • 导入 claude-mem（去重）          │
  │                              │   • 报告缺失插件                    │
```

### 设备标识

每台设备用硬件序列号（唯一、稳定）标识，配合用户自定义的友好名称（如 `macmini`、`macbook`）。

### 历史与回滚

每次 push 会创建一个快照。默认保留最近 3 个快照（可配置）。用 `/sync rollback` 恢复任意快照。

### claude-mem 去重

observations 按 `content_hash` 去重，sessions 按 `memory_session_id` 去重，summaries 按 `memory_session_id + prompt_number` 去重。不会丢失或重复数据。

### 自动提醒

打开 Claude Code 时，自动检查远程是否有新变更，如果另一台设备推送了更新，会提醒你拉取。

## 配置

本地配置存储在 `~/.claude-sync/config.json`：

```json
{
  "version": 1,
  "repo": "username/claude-cowork-sync",
  "device": {
    "id": "设备序列号",
    "name": "macmini",
    "label": "公司 Mac mini"
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

## 安全性

- **私有仓库**：所有同步数据存储在私有 GitHub 仓库中
- **不同步密钥**：OAuth token、API key、credentials 会从 settings.json 中剥离
- **本地备份**：每次 pull 前会创建本地配置的时间戳备份

## 系统要求

- macOS（使用 `ioreg` 获取设备序列号）
- GitHub CLI (`gh`) 已认证
- `jq` JSON 处理工具
- `sqlite3`（macOS 自带）用于 claude-mem 导出导入
- `git`

## 许可证

MIT
