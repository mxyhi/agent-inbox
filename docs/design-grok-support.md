# 设计：支持 Grok 会话源

**状态**: P0 已实现（2026-07-15）
**日期**: 2026-07-15
**范围**: Agent Inbox 从「仅 Codex」扩展为「多 Agent 源」，首批落地 Grok

### 已锁定决策

| # | 决策 |
| --- | --- |
| 1 | 待办触发：`turn_ended(completed)` 即进待办（= agent 等下一步提示；**不**等进程退出） |
| 2 | 会话 id **不改前缀**；新增 `provider` 字段；完成集合用复合键 |
| 3 | UI：混排 + 源标签 |
| 4 | 默认 Codex+Grok 双源全开，**不做**设置开关 |

---

## 1. 背景与目标

### 现状

Agent Inbox 只扫描 `~/.codex/sessions/**/rollout-*.jsonl`：

| 能力 | 实现 |
| --- | --- |
| 扫描 | `CodexSessionMonitor` actor + mtime 缓存 |
| 状态 | `CodexStatusResolver`：running / completed / stale |
| 模型 | `CodexSessionSummary` 硬编码 Codex 语义 |
| 监听 | `CodexSessionsWatcher` 单根 FSEvents |
| UI | 行/焦点卡/打开/完成 全部绑定 Codex 类型名 |

### 目标

1. 同时跟踪 **Codex + Grok** 会话，统一进入现有「运行中 / 待办」列表。
2. 产品语义不变：运行中 = 正在干活；待办 = 干完了等你确认。
3. 架构上为后续 Claude 等源预留 `AgentProvider` 扩展点，但 **本期不实现 Claude**。
4. 允许打破旧命名/持久化格式（项目规则：No backward compatibility）。

### 非目标

- 不在 Inbox 内 resume/attach Grok TUI（打开仍走 cwd / 自定义命令）。
- 不解析 subagent 内部细节为独立待办（子会话若有独立 dir，按普通会话处理）。
- 不做跨机/远程会话。
- 不改通知/置顶/过滤规则的产品语义，只让其吃统一摘要。

---

## 2. 领域映射（关键）

### 2.1 统一术语

| 术语 | 定义 |
| --- | --- |
| **会话源 (AgentProvider)** | 会话数据来源：`codex` / `grok` |
| **会话摘要 (SessionSummary)** | 跨源统一的会话视图（原 `CodexSessionSummary`） |
| **运行中** | Agent 当前正在执行一轮工作 |
| **待办** | 一轮/一次会话工作已结束，用户尚未在 Inbox 确认 |
| **跟踪起点** | `trackingStartedAt`：此前完成的历史不进待办 |

### 2.2 Codex（保持现语义）

| Inbox 字段 | Codex 信号 |
| --- | --- |
| sessionID | `session_meta.id`（**保持原值，不加前缀**） |
| provider | 固定 `.codex` |
| cwd / startedAt | `session_meta` |
| running | tail lifecycle = running，且 mtime 在 stale 窗内 |
| completed / taskCompletedAt | `task_complete` / `turn_complete` |
| firstPrompt | 首个 `user_message` |
| lastAgentMessage | `task_complete.last_agent_message` |
| filePath | rollout jsonl 路径 |

### 2.3 Grok（本机真值，2026-07-15 实测）

**布局**

```
~/.grok/sessions/<url-encoded-cwd>/<session-id>/
  summary.json          # id/cwd/时间/title/model
  events.jsonl          # turn_started / turn_ended / phase_changed / tool_*
  updates.jsonl         # ACP：user/agent_message_chunk, turn_completed
  chat_history.jsonl    # 原始消息（偏大，非主路径）
~/.grok/active_sessions.json   # [{session_id,pid,cwd,opened_at}]
```

**实测信号**

| 信号 | 用途 |
| --- | --- |
| `events.jsonl` → `turn_started` | 一轮开始 |
| `events.jsonl` → `turn_ended` (`outcome: completed`) | 一轮结束 |
| `events.jsonl` → `phase_changed` | streaming / tool_execution / waiting_for_model …（辅助，不单独定态） |
| `active_sessions.json` + `kill(pid,0)` | 进程是否仍活（有僵尸 pid，**必须校验**） |
| `summary.json` | id、cwd、created_at、updated_at/last_active_at、generated_title |
| `updates.jsonl` → `user_message_chunk` | firstPrompt |
| `updates.jsonl` → `agent_message_chunk` | lastAgentMessage（拼最近一轮 text） |

### 2.4 Grok 状态机（产品语义：agent 等下一步提示）

产品目标是**提示用户 agent 已停住、在等下一步提示**，不是等 TUI 进程退出。
`turn_ended(completed)` = 一轮交付结束 = 待办；进程仍活是交互式常态。

```
                    turn_started
   (hidden/idle) ───────────────► running
         ▲                           │
         │                     turn_ended(completed)
         │  用户再发消息 / 下一轮        │
         └───────────────────────────┘
                                     ▼
                                   todo  ← 进程活着也进待办
                                     │
                              用户点完成
                                     ▼
                                  (hidden)
                     再次 turn_started 时解除完成标记
```

| 状态 | 判定 |
| --- | --- |
| **running** | `events` 尾部最近 turn 为 started（无后续 ended），**且** pid 存活 |
| **todo** | 最近 `turn_ended.outcome=completed`；未确认（或已确认但之后又 running 过并再 ended）；完成时间在 retention 内；有有效用户输入 |
| **忽略** | 无用户 query 的空会话；aborted；mid-turn 但 pid 已死 |
| **stale running** | mid-turn 但 pid 死 → 不展示 running |

**身份规范（决策 2）**：

- `sessionID`：各源原生 id（Codex/Grok 都不加前缀）。
- `provider`：新增枚举字段 `.codex` / `.grok`。
- SwiftUI / 完成集合唯一键：`identityKey = "\(provider.rawValue):\(sessionID)"`（仅内部键，不改写原生 sessionID）。
- `completedSessionIDs` 存 `identityKey`；旧库里无前缀的 Codex id 读取时归一成 `codex:<id>`（一次性迁移，日志记录）。若坚持零迁移，也可启动时清空 completed——但「新增字段 + 读时归一」更稳，且 Codex 原生 id 字段本身不变。

**modifiedAt**：`max(summary.updated_at/last_active_at, events.jsonl mtime, summary.json mtime)`。

**taskCompletedAt（待办排序）**：最近一次 `turn_ended` 的 `ts`；若进程退出时无 ended，用 `last_active_at` / 目录 mtime 兜底。

**firstPrompt**：`updates.jsonl` 首个非空 `user_message_chunk`；清洗规则复用 Codex（首行 + 截断）。fallback：`summary.generated_title` / `session_summary`。

**lastAgentMessage**：最近一轮 `agent_message_chunk` 文本拼接后截断；若空则 fallback 到 `generated_title`。

---

## 3. 架构方案

### 3.1 原则

- **深模块、浅接口**：UI / Resolver / Store 只认 `SessionSummary`，不认源格式。
- **源适配器隔离**：Codex / Grok 各自解析，互不泄漏 JSON schema。
- **合成在边界**：`CompositeSessionMonitor` 只做 scan 合并，不做状态策略。
- **KISS**：不引入插件系统、不动态加载；编译期内枚举 provider。

### 3.2 目标结构

```
AgentInboxCore
├── Models.swift
│     AgentProvider { codex, grok }
│     SessionSummary          # 原 CodexSessionSummary + provider
│     TurnLifecycleState      # 原 CodexTurnLifecycleState
│     AgentSnapshot
├── SessionMonitoring.swift   # protocol SessionMonitoring
├── CodexSessionMonitor.swift # 实现 SessionMonitoring（现有逻辑，id 加前缀）
├── GrokSessionMonitor.swift  # 新：summary + events + active_sessions
├── CompositeSessionMonitor.swift
├── AgentStatusResolver.swift # 原 CodexStatusResolver，与源无关
├── OpenSessionExecutor.swift # 入参改 SessionSummary；filePath=会话目录亦可
└── StateStore.swift          # completed id 带 provider 前缀；可重置 tracking

AgentInboxApp
├── AppViewModel              # monitor: any SessionMonitoring
├── SessionsWatcher           # 多 root FSEvents（或 N 个 watcher）
├── Views/*                   # SessionSummary；可选 provider 角标
└── SettingsView              # 源开关 + 路径展示
```

### 3.3 核心接口（示意）

```swift
public enum AgentProvider: String, Codable, Sendable {
    case codex
    case grok

    public var idPrefix: String { rawValue } // "codex" / "grok"
}

public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public let provider: AgentProvider
    /// 源原生会话 id（Codex/Grok 均保持原格式，不加前缀）
    public let sessionID: String
    public let filePath: String           // rollout 或 session dir
    public let cwd: String?
    public let startedAt: Date?
    public let modifiedAt: Date
    public let lifecycleState: TurnLifecycleState
    public let taskCompletedAt: Date?
    public let lastAgentMessage: String?
    public let firstPrompt: String?

    /// ForEach / 完成集合唯一键：provider + 原生 id
    public var id: String { "\(provider.rawValue):\(sessionID)" }
}

public protocol SessionMonitoring: Sendable {
    var roots: [URL] { get }
    func scan() async -> [SessionSummary]
    func scanChangedPaths(_ paths: [String]) async -> [SessionSummary]
}
```

`CompositeSessionMonitor`：并行 `async let` 扫各源，concat；同 id 理论上不应冲突。

### 3.4 GrokSessionMonitor 解析策略（性能）

| 步骤 | IO | 说明 |
| --- | --- | --- |
| 1 | 读 `active_sessions.json` | 得到候选 running + pid 表 |
| 2 | 枚举 sessions 下最近 N 个 `summary.json`（mtime） | 默认 maxFiles=80，与 Codex 一致 |
| 3 | mtime 缓存命中则跳过 | key=session dir，指纹=`summary mtime + events mtime + pidAlive` |
| 4 | 解析 `summary.json`（小） | meta |
| 5 | tail `events.jsonl`（如 64–128KB） | 最近 turn_started/ended |
| 6 | 按需 head/tail `updates.jsonl` | firstPrompt / lastAgentMessage；缓存 |
| 7 | **不**默认读 `chat_history.jsonl` | 体积大、字段冗余 |

日志：`Logger(subsystem: "agent-inbox", category: "GrokSessionMonitor")`，记录扫描数、缓存命中、pid 僵尸数、解析失败路径。

### 3.5 监听

- roots：`~/.codex/sessions` + `~/.grok/sessions` + 可选监听 `~/.grok/active_sessions.json`（父目录 `~/.grok` 过宽，优先精确路径）。
- 实现：`SessionsWatcher` 支持多 root；debounce 合并路径后 `scanChangedPaths`。
- 60s full reconcile 保留。

### 3.6 UI（决策 3）

| 点 | 方案 |
| --- | --- |
| 列表混排 | 按完成时间 / 活跃时间全局排序，**不**按源分栏 |
| 源识别 | 项目名旁小标签 `Codex` / `Grok`（secondary，克制） |
| 空态文案 | 保持中性 `Agent` |
| 设置 | **不提供源开关**（决策 4）；路径展示可顺带列出 Grok 根目录（只读信息，非开关） |
| 打开 | 仍用 cwd；P1 可选 `$provider` / 原生 `$session_id` |
| 过滤 | firstPrompt 规则跨源共用 |

### 3.7 持久化（决策 2 + 4）

- `completedSessionIDs` 存 `identityKey`（`codex:…` / `grok:…`）。
- 加载时：无 `:` 的旧 id 视为 Codex，归一为 `codex:<old>`（原生 `sessionID` 字段仍是 old 本身）。
- **不**引入 `enabledProviders`；双源编译期常开。

---

## 4. 方案对比（为何不选）

| 方案 | 说明 | 否决/采用 |
| --- | --- | --- |
| A. 只在 UI 再开一个 Grok 列表 | 双状态机、双完成集合 | 否：产品要统一关注面 |
| B. 把 Grok 伪造成 Codex jsonl | 脆弱适配 | 否：格式差太大 |
| C. 统一 SessionSummary + 多 Monitor | 深模块边界清晰 | **采用** |
| D. 进程退出才待办 | 错过「等下一步」主场景 | 否：产品要的就是 turn_ended 提醒 |
| E. turn_ended 即待办 | 对齐「agent 等下一步」 | **采用**；同会话多轮靠完成标记在 running 时 rearm |

---

## 5. 风险与对策

| 风险 | 对策 |
| --- | --- |
| `active_sessions` 残留死 pid | 一律 `kill(pid,0)` 校验 |
| Grok 格式小版本变更 | 解析容错 + 字段缺失降级；单测钉死 fixture |
| updates.jsonl 很大 | 只 tail/head 限额；mtime 缓存 |
| 与 Codex 完成 id 混用 | 强制 provider 前缀 |
| 编码 cwd 目录名 >255 | Grok 文档：slug+hash + `.cwd` 文件；解析时读 `.cwd` fallback |
| 权限弹窗中的会话 | phase=`permission_prompt` 仍属 mid-turn → running，正确 |

---

## 6. 分阶段落地

### P0 — 可合并进主列表（默认双源全开）

1. 模型：`SessionSummary` + `provider` + `sessionID`；`id` 为复合键。
2. Codex monitor：产出 `provider=.codex`，`sessionID` 仍为原 id。
3. `GrokSessionMonitor` + fixture 单测。
4. `CompositeSessionMonitor` 接入 `AppViewModel`（无开关）。
5. 多 root watcher。
6. UI 混排 + `Codex`/`Grok` 标签。
7. completed 集合改存/归一 `identityKey`。

**验收**

- 存活 Grok 且 mid-turn → 运行中 + Grok 标签。
- turn_ended 且进程仍活 → **进待办**（等下一步提示）。
- 用户确认后同一会话再 turn_started → 解除完成标记；再 turn_ended → 再次待办/通知。
- Codex 回归：`swift test` 全绿；旧 completed 无前缀 id 仍能命中（读时归一）。

### P1 — 体验（可选后续）

1. 设置页只读展示 Grok 路径（非开关）。
2. `$provider` 打开变量；示例 `grok --resume $session_id`。
3. 通知文案带源名。

### P2 — hardening

1. 长路径 `.cwd`。
2. subagent 目录策略。
3. 解析失败日志硬化。

---

## 7. 测试计划

| 层 | 内容 |
| --- | --- |
| Fixture | 裁剪真实 `summary` + `events` + `updates` + `active_sessions` |
| Monitor | mid-turn running；活进程+ended=隐藏；死进程=todo；僵尸 pid；缓存；坏 JSON |
| Resolver | 混源排序、identityKey completed、trackingStartedAt、filter |
| 迁移 | 旧无前缀 completed id → 视为 codex |
| 集成 | 双源 temp dir refresh |

---

## 8. 成功标准

1. Codex 行为零回归。
2. Grok 无「每 reply 一条待办」风暴。
3. 主线程零文件 IO。
4. 关键路径有注释 + `Logger`。
5. 落地后同步 `CONTEXT.md` / `DESIGN.md`。

---

## 9. 实现任务分解（P0）

| # | 任务 | 主要文件 | 验证 |
| --- | --- | --- | --- |
| T1 | 领域模型：`AgentProvider`、`SessionSummary(provider,sessionID)`、`identityKey`、类型重命名 | `Models.swift` + 全仓引用 | 编译 |
| T2 | completed 读写归一（旧 id → `codex:`） | `StateStore.swift` + 测试 | 单测 |
| T3 | Codex monitor 填 `provider=.codex`，逻辑不变 | `CodexSessionMonitor.swift` | 现有 monitor 测绿 |
| T4 | Resolver/过滤/打开 改用 `SessionSummary` + identityKey | `AgentStatusResolver` 等 | 现有 resolver 测绿 |
| T5 | 新建 `GrokSessionMonitor`（active_sessions+pid、events tail、summary、updates 限额） | 新文件 + fixtures | 新单测 |
| T6 | `CompositeSessionMonitor` + AppViewModel 双源 | `AppViewModel.swift` | 集成测/手测 |
| T7 | 多 root FSEvents watcher | `SessionsWatcher` | 手测增量刷新 |
| T8 | UI 标签混排 | `SessionRow` / `PanelRoot` | 预览/手测 |
| T9 | 文档：`CONTEXT.md` 术语、`DESIGN.md` 架构 | docs | 审阅 |

**建议实现顺序**：T1 → T2 → T3/T4 → T5 → T6/T7 → T8 → T9。