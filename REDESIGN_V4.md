# m-todo V4 设计:动效驱动的会话列表

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
│ ◎ m-todo          3 分钟前  (✓) │ ← 待办区:完成时间倒序,首个带摘要
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
MTodoCore
├── Models.swift              # 契约:CodexSessionSummary(+cwd/startedAt)、AgentSnapshot、PanelAnchor
├── CodexSessionMonitor.swift # actor:后台扫描 + mtime 缓存(未变更文件零重解析)
│                             #   head 8KB → session_meta(id/cwd/startedAt)
│                             #   tail 256KB → task_complete(完成时间/最后消息)
├── CodexStatusResolver.swift # 纯函数:summaries → AgentSnapshot(排序/过滤)
└── StateStore.swift          # SQLite:pin_mode / completed_sessions / panel_anchor

MTodoApp
├── MTodoApp.swift            # 入口:prepare(载锚点) → 建浮窗 → start(轮询)
├── AppViewModel.swift        # snapshot 发布 + 乐观更新(完成即时剔除)
├── FloatingPanelController.swift # 尺寸自适应 + 右上锚定 + 位置持久化(防抖 400ms)
├── DesignSystem.swift        # DS:色彩/字体/间距/动画(单文件)
└── Views/
    ├── PanelRoot.swift       # 胶囊⇄列表分发 + 材质 + 描边 + 右键菜单
    ├── SessionRow.swift      # TodoRow / RunningRow / CompleteButton
    ├── StatusOrb.swift       # 呼吸/涟漪光点(phaseAnimator/keyframeAnimator)
    ├── TimeText.swift        # 相对时间(60s)/ 运行时长(1s,等宽数字)
    ├── VisualEffectBackground.swift
    └── MenuBar.swift         # 菜单栏 + 设置
```

## 顺手修掉的 bug

- `ISO8601DateFormatter` 默认不解析带毫秒的时间戳(`2026-07-04T14:23:29.440Z` → nil),task_complete 时间一直在静默 fallback 到文件 mtime。V4 用 `.withFractionalSeconds` + 无小数秒双 formatter。
