import Foundation

/// 状态归并器:把跨源扫描结果与用户已确认集合归并为 UI 快照
///
/// 纯函数、无内部状态,所有排序/过滤规则集中在此,便于单测覆盖。
/// completedSessionIDs 存 `provider:sessionID` 复合键(见 SessionIdentity)。
public struct AgentStatusResolver: Sendable {
    /// 运行中判定窗口:未完成会话超过该时长无写入即视为已死(stale),不再展示
    private let staleRunningInterval: TimeInterval
    /// 待办时效窗口:完成超过该时长仍未确认的会话不再算待办
    /// (待办语义 = 「最近需要你确认的工作」;没有窗口的话,历史会话会堆出几十个僵尸待办)
    private let todoRetentionInterval: TimeInterval

    public init(
        staleRunningInterval: TimeInterval = 120,
        todoRetentionInterval: TimeInterval = 24 * 3600
    ) {
        self.staleRunningInterval = staleRunningInterval
        self.todoRetentionInterval = todoRetentionInterval
    }

    /// 把原始扫描结果解析为 UI 快照:待办优先、运行中次之
    /// - running:lifecycle 是 running,且 staleRunningInterval 内有写入,最近活跃在前
    /// - todos:lifecycle 是 completed、尚未确认、完成时间在 todoRetentionInterval 内,最新完成在前
    /// - hasCompletedHistory:用户历史上是否手动确认过任务
    public func resolve(
        summaries: [SessionSummary],
        completedSessionIDs: Set<String>,
        promptFilterRules: [PromptFilterRule] = [],
        trackingStartedAt: Date = .distantPast,
        now: Date = Date()
    ) -> AgentSnapshot {
        // 运行中:lifecycle 仍是 running,并且最近仍有写入
        let running = summaries
            .filter { $0.lifecycleState == .running && now.timeIntervalSince($0.modifiedAt) <= staleRunningInterval }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        // 待办:completed、用户尚未确认、仍在时效窗口;按完成时间降序
        // taskCompletedAt 为 nil 视为 distantPast,避免 malformed complete 进入待办
        let todos = summaries
            .filter {
                $0.lifecycleState == .completed
                    && !completedSessionIDs.contains($0.id)
                    && !shouldHideFromTodos($0, rules: promptFilterRules)
                    && ($0.taskCompletedAt ?? .distantPast) >= trackingStartedAt
                    && now.timeIntervalSince($0.taskCompletedAt ?? .distantPast) <= todoRetentionInterval
            }
            .sorted { ($0.taskCompletedAt ?? .distantPast) > ($1.taskCompletedAt ?? .distantPast) }

        return AgentSnapshot(
            todos: todos,
            running: running,
            hasCompletedHistory: !completedSessionIDs.isEmpty
        )
    }

    private func shouldHideFromTodos(_ summary: SessionSummary, rules: [PromptFilterRule]) -> Bool {
        rules.contains { $0.matches(summary) }
    }
}

/// 历史命名兼容;新代码用 AgentStatusResolver。
public typealias CodexStatusResolver = AgentStatusResolver
