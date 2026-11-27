# Agent Inbox 设计

## V5：tic 便签外壳（2026-11-27）

App 层改用 [tic](https://github.com/mxyhi/tic)（MIT，基于 84bb4fe，许可见 `ThirdParty/tic/LICENSE`）的便签窗口层。`AgentInboxCore` 不变；V4 的状态点、会话行与待办语义保留，V4 的浮窗（`FloatingPanelController`、胶囊空态、内容驱动尺寸、右上锚点）废弃。

### 决策

- **收件箱就是一张 tic 清单**：`note.kind = agentInbox`，tic 的 UI 与功能原样保留（加任务、子任务、拖拽、贴图、卷起、贴边停靠、图钉、材质、隐私）。唯一的区别是任务列表最上面插入 `InboxSessionRows`：待办行和运行中行，样式照搬 `TaskRowView`。点圆圈标记已处理，点文字打开会话，右键可按提示词过滤。卷起条和停靠 tab 的数字 = Agent 待办 + 未完成任务。
- **待办不写入 task 表**：快照仍是「日志 → CompositeSessionMonitor → AgentStatusResolver」推导，确认仍写 `state.sqlite`。便签行只存窗口状态，避免日志状态与任务行双向同步。
- **置顶用 tic 的图钉**：旧的「置顶模式」不再使用（Core 里的 `pinMode` 仍会读写，App 不读）。首次创建的收件箱默认置顶。
- **隔离**：收件箱不进 `allNotes`/`observeNotes`（菜单栏、清单面板、MCP）、不进同步记录，MCP 按 id 访问也拒绝。新清单命名只数清单。
- **保留 tic 功能**：清单、文件夹同步、MCP、搜索面板、Dock 图标。tic 自带的 GitHub Releases 更新器删除，统一用 Sparkle 与原 bundle ID，已安装版本原地升级。

### 迁移边界

- 便签库是新文件 `~/Library/Application Support/Agent Inbox/notes.sqlite`；`state.sqlite` 原样沿用。首次启动用旧 `panelAnchor` 摆放收件箱便签，之后不再读写该锚点。
- 不再种入 tic 的欢迎清单；同步文件夹默认 `iCloud Drive/Agent Inbox`，与独立安装的 Tic.app 互不干扰。
- 从 accessory 变为 Dock + 菜单栏双入口（tic 的交互依赖前台激活）；打包不再写 `LSUIElement`。
- 界面语言：收件箱与菜单栏中文，tic 的清单、设置通用页仍为英文（未做本地化）。

### 结构

```
AgentInboxApp
├── AgentInboxApp.swift / AppDelegate.swift / AppModel.swift   # 菜单栏、启动顺序、收件箱置顶
├── Inbox/                      # InboxModel（原 AppViewModel）、FSEvents、通知、Sparkle、InboxSessionRows、设置标签页
├── Windows/ Views/ Controllers/ Models/ Database/ Sync/ MCP/   # tic 便签层（NoteView 按 kind 分支）
```

---

## V4：动效驱动的会话列表（窗口部分已被 V5 取代）

**版本**: 4.0 · **日期**: 2026-07-04

## V3 被否的病根

1. **假毛玻璃**:`windowBackgroundColor(0.8)` 叠 `ultraThinMaterial(0.5)` 是浑浊的灰,不是系统 vibrancy
2. **无描边**:浅色壁纸下浮窗边缘糊成一片
3. **信息本身丑**:展示 `rollout-*.jsonl` 文件名(技术噪音),而 session_meta 里就有 `cwd`(项目名)、`timestamp`(启动时间),task_complete 里有 `last_agent_message`(Codex 干了什么)
4. **chrome 过剩**:2s 自动轮询下还有常驻「刷新」按钮
5. **固定 320×200**:空闲时 84% 是空白
6. **主线程 IO**:每 2s 在 main actor 同步读 80 个文件

## V4 设计决策

### 状态不用文字,用动效(用户反馈)

| 状态 | 表达 |
| --- | --- |
| 运行中 | 蓝点呼吸(缩放+光晕,1.8s 周期)+ 秒级跳动的运行时长 |
| 待办 | 橙点涟漪扩散(每 2.5s 一圈)+ 消息摘要 |
| 空闲 | 静止灰点微胶囊 |
| 全部完成 | 绿色对勾微胶囊 |

面板上没有「运行中/等待确认」这类状态词。reduceMotion 时动效退化为静止点。

### 待办优先的列表(用户反馈)

单焦点状态机(`AgentDisplayState`)废弃,改为 `AgentSnapshot { todos, running }`:

```
╭─ 会话列表(300pt 宽,高度自适应)─╮
│ ◎ agent-inbox          3 分钟前  (✓) │ ← 待办区:完成时间倒序,首个带摘要
│   审计完了,基于本机 codex-cli…    │
│ ◎ _all_do         1 小时前  (✓) │
│ ────────────────────────────    │
│ ● side-project           2:34   │ ← 运行区:活跃倒序,时长实时
╰─────────────────────────────────╯
```

每区最多 3 条,溢出折叠为「还有 N 个」。空态收缩为微胶囊(`○ Codex`)。

### 去 chrome

面板唯一按钮 = 待办行的圆形完成按钮(hover 变绿)。刷新/置顶模式/设置/隐藏/退出全部收进**右键菜单**;菜单栏下拉可逐个/批量完成待办。

### 视觉

- 材质:`NSVisualEffectView(.popover, behindWindow, active)` —— 真 vibrancy,明暗自适应
- 描边:0.5pt `separatorColor` 发丝线
- 色彩:文本全部 `.primary/.secondary`;彩色只在状态点与完成按钮 hover(系统蓝/橙/绿)
- 窗口:内容驱动尺寸(`NSHostingView.sizingOptions = .preferredContentSize`),resize 后回钉右上锚点,胶囊⇄列表弹簧收放

## V4 架构

```
AgentInboxCore
├── Models.swift                 # AgentProvider、SessionSummary、AgentSnapshot、SessionIdentity
├── CodexSessionMonitor.swift    # actor:扫 ~/.codex/sessions rollout jsonl + mtime 缓存
├── GrokSessionMonitor.swift     # actor:扫 ~/.grok/sessions + active_sessions/pid + events tail
├── ClaudeSessionMonitor.swift   # actor:扫 ~/.claude/projects transcript + Claude live 状态
├── CompositeSessionMonitor.swift# 并行合并 Codex+Grok+Claude
├── CodexStatusResolver.swift    # AgentStatusResolver:summaries → AgentSnapshot
├── OpenSessionExecutor.swift    # 打开 cwd / 自定义命令($session_id/$provider/…)
└── StateStore.swift             # SQLite;completed 存 provider:sessionID

AgentInboxApp
├── AgentInboxApp.swift
├── AppViewModel.swift           # Composite 扫描 + 快照发布 + 完成乐观更新
├── SessionsWatcher.swift        # 多 root FSEvents(Codex+Grok+Claude+active_sessions 父目录)
├── FloatingPanelController.swift
├── DesignSystem.swift
└── Views/
    ├── PanelRoot.swift
    ├── SessionRow.swift         # 混排 + ProviderTag(Codex/Grok/Claude)
    ├── StatusOrb.swift
    ├── TimeText.swift
    ├── VisualEffectBackground.swift
    └── MenuBar.swift
```

## 多源会话(P0,2026-07-15)

- 统一模型:`SessionSummary { provider, sessionID, … }`,`id = provider:sessionID`。
- Grok 待办语义:`turn_ended(completed)` 即进待办(= agent 等下一步提示);不要求进程退出。同会话多轮:再次 `running` 时解除完成标记。
- 设计细则见 `docs/design-grok-support.md`。

## Claude Code 会话源(P0,2026-08-08)

- 扫描 `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` 顶层 transcript；嵌套 subagent/tool-results 不独立入箱。
- `claude agents --json` 补充 live `active`/`idle` 状态；CLI 不可用时退化到 transcript `stop_hook_summary`/`turn_duration`。
- 一轮停止并等待下一步输入即进入待办，不要求 Claude 进程退出。
- 不安装 Claude Hook，不修改用户 `~/.claude`；打开会话可用自定义模板 `claude --resume "$session_id"`。
- 设计细则见 `docs/design-claude-support.md`。

## 顺手修掉的 bug

- `ISO8601DateFormatter` 默认不解析带毫秒的时间戳(`2026-07-04T14:23:29.440Z` → nil),task_complete 时间一直在静默 fallback 到文件 mtime。V4 用 `.withFractionalSeconds` + 无小数秒双 formatter。
