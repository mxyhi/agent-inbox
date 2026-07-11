import Foundation
import Testing
@testable import AgentInboxCore

/// 构造状态转换测试所需的最小会话摘要。
private func makeTransitionSummary(
    id: String,
    lifecycleState: CodexTurnLifecycleState,
    taskCompletedAt: Date? = nil
) -> CodexSessionSummary {
    let now = Date(timeIntervalSince1970: 10_000)
    return CodexSessionSummary(
        id: id,
        filePath: "/tmp/rollout-\(id).jsonl",
        cwd: "/tmp/project-\(id)",
        startedAt: now.addingTimeInterval(-60),
        modifiedAt: now,
        lifecycleState: lifecycleState,
        taskCompletedAt: taskCompletedAt,
        lastAgentMessage: nil
    )
}

@Test
func runningSessionTransitioningToTodoIsNewTodo() {
    let now = Date(timeIntervalSince1970: 10_000)
    let running = makeTransitionSummary(id: "session", lifecycleState: .running)
    let todo = makeTransitionSummary(
        id: "session",
        lifecycleState: .completed,
        taskCompletedAt: now
    )
    let previous = AgentSnapshot(todos: [], running: [running], hasCompletedHistory: false)
    let next = AgentSnapshot(todos: [todo], running: [], hasCompletedHistory: false)

    #expect(next.newTodos(comparedTo: previous).map(\.id) == ["session"])
}

@Test
func todoDiscoveredWithoutObservedRunningStateIsNotNewTodo() {
    let todo = makeTransitionSummary(
        id: "existing",
        lifecycleState: .completed,
        taskCompletedAt: Date(timeIntervalSince1970: 10_000)
    )
    let next = AgentSnapshot(todos: [todo], running: [], hasCompletedHistory: false)

    // 启动首扫从空快照直接发现历史待办时必须保持静默。
    #expect(next.newTodos(comparedTo: .empty).isEmpty)
}

@Test
func repeatedTodoSnapshotDoesNotCreateAnotherNewTodo() {
    let todo = makeTransitionSummary(
        id: "existing",
        lifecycleState: .completed,
        taskCompletedAt: Date(timeIntervalSince1970: 10_000)
    )
    let snapshot = AgentSnapshot(todos: [todo], running: [], hasCompletedHistory: false)

    #expect(snapshot.newTodos(comparedTo: snapshot).isEmpty)
}

@Test
func multipleRunningSessionsTransitionInTodoOrder() {
    let now = Date(timeIntervalSince1970: 10_000)
    let existingTodo = makeTransitionSummary(
        id: "existing",
        lifecycleState: .completed,
        taskCompletedAt: now.addingTimeInterval(-60)
    )
    let firstRunning = makeTransitionSummary(id: "first", lifecycleState: .running)
    let secondRunning = makeTransitionSummary(id: "second", lifecycleState: .running)
    let firstTodo = makeTransitionSummary(id: "first", lifecycleState: .completed, taskCompletedAt: now)
    let secondTodo = makeTransitionSummary(id: "second", lifecycleState: .completed, taskCompletedAt: now)
    let previous = AgentSnapshot(
        todos: [existingTodo],
        running: [firstRunning, secondRunning],
        hasCompletedHistory: false
    )
    let next = AgentSnapshot(
        todos: [secondTodo, existingTodo, firstTodo],
        running: [],
        hasCompletedHistory: false
    )

    // 保留新快照排序，但排除原本已存在的待办。
    #expect(next.newTodos(comparedTo: previous).map(\.id) == ["second", "first"])
}
