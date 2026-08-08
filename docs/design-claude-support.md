# 设计：支持 Claude Code 会话源

**状态**: P0 已实现（2026-08-08）
**范围**: Claude Code 会话进入 Agent Inbox 统一运行中/待办列表

## 决策

1. 默认启用 Claude Code，会话与 Codex/Grok 混排，不增加 provider 开关。
2. 被动读取 Claude 原生 transcript，不安装 Hook、不修改 `~/.claude`。
3. `claude agents --json` 只补充 live 状态；CLI 缺失或失败时继续使用 transcript 回退信号。
4. 一轮停止并等待下一步输入就是待办，不要求 Claude 进程退出。
5. subagent、tool result、memory 等嵌套文件不成为独立会话。

## 数据映射

Claude Code 当前本地布局：

```text
~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
~/.claude/projects/<encoded-cwd>/<session-id>/subagents/*.jsonl
```

| Inbox 字段 | Claude Code 信号 |
| --- | --- |
| provider | `.claude` |
| sessionID | transcript `sessionId`，缺失时退化为文件名 |
| cwd | transcript 顶层 `cwd` |
| startedAt | 首个可解析 `timestamp` |
| firstPrompt | 首个非 meta、非自动标题的 user 文本 |
| lastAgentMessage | 尾部最近 assistant `text` block |
| running | live status 为 `active`，或最新 transcript 信号仍在活动 |
| completed | live status 为 `idle`，或尾部 `stop_hook_summary`/`turn_duration` |

## 性能边界

- 只枚举 `projects/<project>/*.jsonl` 两层，不递归进入 subagent/tool-results/memory。
- 每源最多保留最近 80 个 transcript，按 mtime 缓存 head/tail 解析结果。
- head/tail 各最多读取 256 KiB；live CLI 查询有 2 秒缓存。
- FSEvents 只对顶层 transcript 和项目目录变化重扫，忽略更深层噪声。

## 打开会话

统一 `OpenSessionExecutor` 已提供 `$provider`、`$session_id`、`$cwd` 等变量。恢复 Claude 原生会话使用：

```sh
claude --resume "$session_id"
```

Finder、Terminal、VS Code 预设仍只打开会话工作目录。

## 验收

- completed transcript 能提取首个用户提示与最终助手文本，并进入待办候选。
- unfinished transcript 映射为 running；live `active`/`idle` 优先于 transcript 回退。
- 自动标题 prompt 不污染 firstPrompt。
- 嵌套 subagent transcript 不进入主列表。
- Codex/Grok/Claude 全部通过同一 `AgentStatusResolver`、复合会话身份与完成确认流程。
