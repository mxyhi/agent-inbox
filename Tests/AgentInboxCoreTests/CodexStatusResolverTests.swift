import Foundation
import Testing
@testable import AgentInboxCore

/// 构造摘要 fixture 的便捷函数
private func makeSummary(
    id: String,
    modifiedAt: Date,
    lifecycleState: TurnLifecycleState? = nil,
    taskCompletedAt: Date? = nil,
    lastAgentMessage: String? = nil,
    firstPrompt: String? = nil
) -> SessionSummary {
    SessionSummary(
            provider: .codex,
            sessionID: id,
        filePath: "/tmp/rollout-\(id).jsonl",
        cwd: "/tmp/project-\(id)",
        startedAt: modifiedAt.addingTimeInterval(-60),
        modifiedAt: modifiedAt,
        lifecycleState: lifecycleState,
        taskCompletedAt: taskCompletedAt,
        lastAgentMessage: lastAgentMessage,
        firstPrompt: firstPrompt
    )
}

@Test
func defaultPinModeIsTodoOnly() {
    #expect(PersistedState().pinMode == .todoOnly)
}

@Test
func activeOrTodoPinModeFloatsForRunningOrTodo() {
    let now = Date(timeIntervalSince1970: 10_000)
    let running = makeSummary(id: "running", modifiedAt: now.addingTimeInterval(-5))
    let todo = makeSummary(
        id: "todo",
        modifiedAt: now.addingTimeInterval(-10),
        taskCompletedAt: now.addingTimeInterval(-10)
    )

    let runningSnapshot = CodexStatusResolver().resolve(
        summaries: [running],
        completedSessionIDs: [],
        now: now
    )
    let todoSnapshot = CodexStatusResolver().resolve(
        summaries: [todo],
        completedSessionIDs: [],
        now: now
    )

    #expect(PinMode.activeOrTodo.shouldFloat(for: runningSnapshot))
    #expect(PinMode.activeOrTodo.shouldFloat(for: todoSnapshot))
    #expect(!PinMode.activeOrTodo.shouldFloat(for: .empty))
}

@Test
func todoOnlyPinModeFloatsOnlyForTodos() {
    let now = Date(timeIntervalSince1970: 10_000)
    let running = makeSummary(id: "running", modifiedAt: now.addingTimeInterval(-5))
    let todo = makeSummary(
        id: "todo",
        modifiedAt: now.addingTimeInterval(-10),
        taskCompletedAt: now.addingTimeInterval(-10)
    )

    let runningSnapshot = CodexStatusResolver().resolve(
        summaries: [running],
        completedSessionIDs: [],
        now: now
    )
    let todoSnapshot = CodexStatusResolver().resolve(
        summaries: [todo],
        completedSessionIDs: [],
        now: now
    )

    #expect(!PinMode.todoOnly.shouldFloat(for: runningSnapshot))
    #expect(PinMode.todoOnly.shouldFloat(for: todoSnapshot))
}

@Test
func panelPresentationFollowsConfiguredPinMode() {
    let now = Date(timeIntervalSince1970: 10_000)
    let running = makeSummary(id: "running", modifiedAt: now.addingTimeInterval(-5))
    let todo = makeSummary(
        id: "todo",
        modifiedAt: now.addingTimeInterval(-10),
        taskCompletedAt: now.addingTimeInterval(-10)
    )
    let resolver = CodexStatusResolver()
    let runningSnapshot = resolver.resolve(
        summaries: [running],
        completedSessionIDs: [],
        now: now
    )
    let todoSnapshot = resolver.resolve(
        summaries: [todo],
        completedSessionIDs: [],
        now: now
    )

    #expect(PinMode.alwaysOnTop.panelPresentation(for: .empty) == .floatingAcrossFullscreen)
    #expect(PinMode.activeOrTodo.panelPresentation(for: .empty) == .normal)
    #expect(PinMode.activeOrTodo.panelPresentation(for: runningSnapshot) == .floatingAcrossFullscreen)
    #expect(PinMode.activeOrTodo.panelPresentation(for: todoSnapshot) == .floatingAcrossFullscreen)
    #expect(PinMode.todoOnly.panelPresentation(for: .empty) == .normal)
    #expect(PinMode.todoOnly.panelPresentation(for: runningSnapshot) == .normal)
    #expect(PinMode.todoOnly.panelPresentation(for: todoSnapshot) == .floatingAcrossFullscreen)
}

@Test
func panelPresentationControlsWindowOrdering() {
    #expect(PanelPresentation.normal.windowOrdering == .front)
    #expect(PanelPresentation.floatingAcrossFullscreen.windowOrdering == .frontRegardless)
}

@Test
func panelPresentationSuppressesOnlyNormalWindowsBehindFullscreenApps() {
    #expect(PanelPresentation.normal.shouldSuppress(whenFrontmostWindowCoversScreen: true))
    #expect(!PanelPresentation.normal.shouldSuppress(whenFrontmostWindowCoversScreen: false))
    #expect(!PanelPresentation.floatingAcrossFullscreen.shouldSuppress(whenFrontmostWindowCoversScreen: true))
}

@Test
func runningSessionsAreAllKeptAndSortedByRecency() {
    let now = Date(timeIntervalSince1970: 10_000)
    let older = makeSummary(id: "run-older", modifiedAt: now.addingTimeInterval(-60))
    let newer = makeSummary(id: "run-newer", modifiedAt: now.addingTimeInterval(-5))

    let snapshot = CodexStatusResolver().resolve(
        summaries: [older, newer],
        completedSessionIDs: [],
        now: now
    )

    // V4:running 保留全部活跃会话,最近写入的排前面
    #expect(snapshot.running.map(\.id) == ["codex:run-newer", "codex:run-older"])
    #expect(snapshot.todos.isEmpty)
    #expect(snapshot.isActive)
    #expect(!snapshot.hasTodo)
}

@Test
func todosAreAllKeptAndSortedByCompletionTime() {
    let now = Date(timeIntervalSince1970: 10_000)
    let earlier = makeSummary(
        id: "todo-earlier",
        modifiedAt: now.addingTimeInterval(-300),
        taskCompletedAt: now.addingTimeInterval(-200),
        lastAgentMessage: "先完成"
    )
    let later = makeSummary(
        id: "todo-later",
        modifiedAt: now.addingTimeInterval(-100),
        taskCompletedAt: now.addingTimeInterval(-50),
        lastAgentMessage: "后完成"
    )

    let snapshot = CodexStatusResolver().resolve(
        summaries: [earlier, later],
        completedSessionIDs: [],
        now: now
    )

    // V4:todos 保留全部待确认会话,按 taskCompletedAt 降序(新完成的在前)
    #expect(snapshot.todos.map(\.id) == ["codex:todo-later", "codex:todo-earlier"])
    #expect(snapshot.running.isEmpty)
    #expect(snapshot.hasTodo)
    #expect(!snapshot.isActive)
}

@Test
func promptFilterRulesHideMatchingFirstPromptTodos() {
    let now = Date(timeIntervalSince1970: 10_000)
    let titleTask = makeSummary(
        id: "title-task",
        modifiedAt: now.addingTimeInterval(-50),
        taskCompletedAt: now.addingTimeInterval(-50),
        firstPrompt: "Generate a concise tab title for this chat."
    )
    let realTask = makeSummary(
        id: "real-task",
        modifiedAt: now.addingTimeInterval(-40),
        taskCompletedAt: now.addingTimeInterval(-40),
        firstPrompt: "修复生产告警"
    )
    let rule = PromptFilterRule(
        matchType: .contains,
        pattern: "concise tab title"
    )

    let snapshot = CodexStatusResolver().resolve(
        summaries: [titleTask, realTask],
        completedSessionIDs: [],
        promptFilterRules: [rule],
        now: now
    )

    #expect(snapshot.todos.map(\.id) == ["codex:real-task"])
}

@Test
func disabledPromptFilterRulesDoNotHideTodos() {
    let now = Date(timeIntervalSince1970: 10_000)
    let todo = makeSummary(
        id: "title-task",
        modifiedAt: now.addingTimeInterval(-50),
        taskCompletedAt: now.addingTimeInterval(-50),
        firstPrompt: "Generate a concise tab title for this chat."
    )
    let disabledRule = PromptFilterRule(
        isEnabled: false,
        matchType: .contains,
        pattern: "concise tab title"
    )

    let snapshot = CodexStatusResolver().resolve(
        summaries: [todo],
        completedSessionIDs: [],
        promptFilterRules: [disabledRule],
        now: now
    )

    #expect(snapshot.todos.map(\.id) == ["codex:title-task"])
}

@Test
func equalsPromptFilterRulesHideMatchingFirstPromptTodos() {
    let now = Date(timeIntervalSince1970: 10_000)
    let titleTask = makeSummary(
        id: "title-task",
        modifiedAt: now.addingTimeInterval(-50),
        taskCompletedAt: now.addingTimeInterval(-50),
        firstPrompt: "Generate a concise tab title for this chat."
    )
    let rule = PromptFilterRule(
        matchType: .equals,
        pattern: "generate a concise tab title for this chat."
    )

    let snapshot = CodexStatusResolver().resolve(
        summaries: [titleTask],
        completedSessionIDs: [],
        promptFilterRules: [rule],
        now: now
    )

    #expect(snapshot.todos.isEmpty)
}

@Test
func staleIncompleteSessionIsDroppedFromRunning() {
    let now = Date(timeIntervalSince1970: 10_000)
    // 超过 staleRunningInterval 无写入且无 task_complete → 视为已死,任何列表都不出现
    let stale = makeSummary(id: "stale", modifiedAt: now.addingTimeInterval(-500))
    let fresh = makeSummary(id: "fresh", modifiedAt: now.addingTimeInterval(-10))

    let snapshot = CodexStatusResolver(staleRunningInterval: 120).resolve(
        summaries: [stale, fresh],
        completedSessionIDs: [],
        now: now
    )

    #expect(snapshot.running.map(\.id) == ["codex:fresh"])
    #expect(snapshot.todos.isEmpty)
}

@Test
func abortedAndRolledBackSessionsAreDroppedFromRunningAndTodos() {
    let now = Date(timeIntervalSince1970: 10_000)
    let started = makeSummary(
        id: "started",
        modifiedAt: now.addingTimeInterval(-5),
        lifecycleState: .running
    )
    let completed = makeSummary(
        id: "completed",
        modifiedAt: now.addingTimeInterval(-10),
        lifecycleState: .completed,
        taskCompletedAt: now.addingTimeInterval(-10)
    )
    let aborted = makeSummary(
        id: "aborted",
        modifiedAt: now.addingTimeInterval(-3),
        lifecycleState: .aborted
    )
    let rolledBack = makeSummary(
        id: "rolled-back",
        modifiedAt: now.addingTimeInterval(-2),
        lifecycleState: .rolledBack
    )

    let snapshot = CodexStatusResolver(staleRunningInterval: 120).resolve(
        summaries: [started, completed, aborted, rolledBack],
        completedSessionIDs: [],
        now: now
    )

    #expect(snapshot.running.map(\.id) == ["codex:started"])
    #expect(snapshot.todos.map(\.id) == ["codex:completed"])
}

@Test
func confirmedTodosAreFilteredOutAndFeedHistory() {
    let now = Date(timeIntervalSince1970: 10_000)
    let confirmed = makeSummary(
        id: "todo-confirmed",
        modifiedAt: now.addingTimeInterval(-100),
        taskCompletedAt: now.addingTimeInterval(-80)
    )
    let pending = makeSummary(
        id: "todo-pending",
        modifiedAt: now.addingTimeInterval(-60),
        taskCompletedAt: now.addingTimeInterval(-40)
    )

    let snapshot = CodexStatusResolver().resolve(
        summaries: [confirmed, pending],
        completedSessionIDs: ["codex:todo-confirmed"],
        now: now
    )

    // 用户已确认的会话从待办中剔除,同时点亮历史标记
    #expect(snapshot.todos.map(\.id) == ["codex:todo-pending"])
    #expect(snapshot.hasCompletedHistory)
}

@Test
func expiredTodosAreDroppedByRetentionWindow() {
    let now = Date(timeIntervalSince1970: 200_000)
    // 25 小时前完成、一直没确认 → 超出 24h 时效窗口,不再当作待办轰炸用户
    let expired = makeSummary(
        id: "todo-expired",
        modifiedAt: now.addingTimeInterval(-25 * 3600),
        taskCompletedAt: now.addingTimeInterval(-25 * 3600)
    )
    let fresh = makeSummary(
        id: "todo-fresh",
        modifiedAt: now.addingTimeInterval(-600),
        taskCompletedAt: now.addingTimeInterval(-600)
    )

    let snapshot = CodexStatusResolver(todoRetentionInterval: 24 * 3600).resolve(
        summaries: [expired, fresh],
        completedSessionIDs: [],
        now: now
    )

    #expect(snapshot.todos.map(\.id) == ["codex:todo-fresh"])
}

@Test
func todosCompletedBeforeTrackingStartedAtAreHidden() {
    let now = Date(timeIntervalSince1970: 200_000)
    let baseline = now.addingTimeInterval(-1_000)
    let oldBeforeInstall = makeSummary(
        id: "old-before-install",
        modifiedAt: baseline.addingTimeInterval(-10),
        taskCompletedAt: baseline.addingTimeInterval(-10)
    )
    let newAfterInstall = makeSummary(
        id: "new-after-install",
        modifiedAt: baseline.addingTimeInterval(10),
        taskCompletedAt: baseline.addingTimeInterval(10)
    )

    let snapshot = CodexStatusResolver(todoRetentionInterval: 24 * 3600).resolve(
        summaries: [oldBeforeInstall, newAfterInstall],
        completedSessionIDs: [],
        trackingStartedAt: baseline,
        now: now
    )

    // 首次打开 app 之前已经结束的历史会话不进入待办,避免安装后刷出一堆旧任务
    #expect(snapshot.todos.map(\.id) == ["codex:new-after-install"])
}

@Test
func historyFlagReflectsCompletedIDsEvenWithoutSummaries() {
    // 扫描结果为空但历史确认集合非空(rollout 被清理/滚动出窗口)→ 仍是「全部处理完」而非「从未有任务」
    let snapshot = CodexStatusResolver().resolve(
        summaries: [],
        completedSessionIDs: ["codex:old-session"],
        now: Date(timeIntervalSince1970: 10_000)
    )

    #expect(snapshot.isEmpty)
    #expect(snapshot.hasCompletedHistory)
}

@Test
func emptyInputYieldsEmptySnapshotWithoutHistory() {
    let snapshot = CodexStatusResolver().resolve(
        summaries: [],
        completedSessionIDs: [],
        now: Date(timeIntervalSince1970: 10_000)
    )

    #expect(snapshot == .empty)
    #expect(snapshot.isEmpty)
    #expect(!snapshot.hasCompletedHistory)
}
