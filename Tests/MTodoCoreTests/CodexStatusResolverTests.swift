import Foundation
import Testing
@testable import MTodoCore

/// 构造摘要 fixture 的便捷函数
private func makeSummary(
    id: String,
    modifiedAt: Date,
    taskCompletedAt: Date? = nil,
    lastAgentMessage: String? = nil
) -> CodexSessionSummary {
    CodexSessionSummary(
        id: id,
        filePath: "/tmp/rollout-\(id).jsonl",
        cwd: "/tmp/project-\(id)",
        startedAt: modifiedAt.addingTimeInterval(-60),
        modifiedAt: modifiedAt,
        taskCompletedAt: taskCompletedAt,
        lastAgentMessage: lastAgentMessage
    )
}

@Test
func defaultPinModeIsActiveOrTodo() {
    #expect(PersistedState().pinMode == .activeOrTodo)
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
    #expect(snapshot.running.map(\.id) == ["run-newer", "run-older"])
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
    #expect(snapshot.todos.map(\.id) == ["todo-later", "todo-earlier"])
    #expect(snapshot.running.isEmpty)
    #expect(snapshot.hasTodo)
    #expect(!snapshot.isActive)
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

    #expect(snapshot.running.map(\.id) == ["fresh"])
    #expect(snapshot.todos.isEmpty)
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
        completedSessionIDs: ["todo-confirmed"],
        now: now
    )

    // 用户已确认的会话从待办中剔除,同时点亮历史标记
    #expect(snapshot.todos.map(\.id) == ["todo-pending"])
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

    #expect(snapshot.todos.map(\.id) == ["todo-fresh"])
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
    #expect(snapshot.todos.map(\.id) == ["new-after-install"])
}

@Test
func historyFlagReflectsCompletedIDsEvenWithoutSummaries() {
    // 扫描结果为空但历史确认集合非空(rollout 被清理/滚动出窗口)→ 仍是「全部处理完」而非「从未有任务」
    let snapshot = CodexStatusResolver().resolve(
        summaries: [],
        completedSessionIDs: ["old-session"],
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
