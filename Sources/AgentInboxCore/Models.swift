import Foundation

/// 浮窗置顶模式
public enum PinMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case alwaysOnTop
    case activeOrTodo
    case todoOnly

    public var id: String { rawValue }

    /// 设置界面展示文案
    public var label: String {
        switch self {
        case .alwaysOnTop:
            "始终置顶"
        case .activeOrTodo:
            "仅运行中/有待办时置顶"
        case .todoOnly:
            "有待办时置顶"
        }
    }

    /// 根据当前快照判定浮窗是否应进入置顶层级。
    public func shouldFloat(for snapshot: AgentSnapshot) -> Bool {
        switch self {
        case .alwaysOnTop:
            true
        case .activeOrTodo:
            snapshot.isActive || snapshot.hasTodo
        case .todoOnly:
            snapshot.hasTodo
        }
    }
}

/// Codex turn 生命周期状态,来自 rollout 尾部最近的 lifecycle event。
public enum CodexTurnLifecycleState: String, Codable, Equatable, Sendable {
    case running
    case completed
    case aborted
    case rolledBack
    case unknown
}

/// 单个 Codex 会话摘要
/// 由 rollout 文件头部 `session_meta` 与尾部生命周期事件合并而来。
public struct CodexSessionSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let filePath: String
    /// 会话工作目录(session_meta.payload.cwd),UI 用它展示项目名
    public let cwd: String?
    /// 会话启动时间(session_meta.payload.timestamp),UI 用它计算运行时长
    public let startedAt: Date?
    /// rollout 文件最后修改时间,用于活跃度判定
    public let modifiedAt: Date
    /// 最近的 turn 生命周期;aborted/rolledBack 不应继续显示为运行中
    public let lifecycleState: CodexTurnLifecycleState
    /// task_complete 事件时间;nil 表示任务尚未结束
    public let taskCompletedAt: Date?
    /// task_complete.last_agent_message,待办行的摘要正文
    public let lastAgentMessage: String?

    public init(
        id: String,
        filePath: String,
        cwd: String?,
        startedAt: Date?,
        modifiedAt: Date,
        lifecycleState: CodexTurnLifecycleState? = nil,
        taskCompletedAt: Date?,
        lastAgentMessage: String?
    ) {
        self.id = id
        self.filePath = filePath
        self.cwd = cwd
        self.startedAt = startedAt
        self.modifiedAt = modifiedAt
        self.lifecycleState = lifecycleState ?? (taskCompletedAt == nil ? .running : .completed)
        self.taskCompletedAt = taskCompletedAt
        self.lastAgentMessage = lastAgentMessage
    }

    public var isTaskComplete: Bool {
        taskCompletedAt != nil
    }

    /// 项目名:cwd 最后一段;无 cwd 时退化为 rollout 文件名(去扩展名)
    public var projectName: String {
        if let cwd, !cwd.isEmpty {
            return URL(filePath: cwd).lastPathComponent
        }
        return URL(filePath: filePath).deletingPathExtension().lastPathComponent
    }
}

/// 全量状态快照 —— V4 用「待办优先的列表」取代单焦点状态机
public struct AgentSnapshot: Equatable, Sendable {
    /// 等待确认的会话,新完成的排前面
    public let todos: [CodexSessionSummary]
    /// 运行中的会话,最近活跃的排前面
    public let running: [CodexSessionSummary]
    /// 历史上是否手动完成过任务(区分「从未有任务」与「全部处理完」)
    public let hasCompletedHistory: Bool

    public init(
        todos: [CodexSessionSummary],
        running: [CodexSessionSummary],
        hasCompletedHistory: Bool
    ) {
        self.todos = todos
        self.running = running
        self.hasCompletedHistory = hasCompletedHistory
    }

    public static let empty = AgentSnapshot(todos: [], running: [], hasCompletedHistory: false)

    public var isEmpty: Bool { todos.isEmpty && running.isEmpty }
    public var hasTodo: Bool { !todos.isEmpty }
    public var isActive: Bool { !running.isEmpty }
}

/// 浮窗右上角锚点(AppKit 屏幕坐标),用于跨启动恢复窗口位置
public struct PanelAnchor: Codable, Equatable, Sendable {
    public var topRightX: Double
    public var topRightY: Double

    public init(topRightX: Double, topRightY: Double) {
        self.topRightX = topRightX
        self.topRightY = topRightY
    }
}

/// 持久化状态(SQLite)
public struct PersistedState: Codable, Equatable, Sendable {
    public var pinMode: PinMode
    public var completedSessionIDs: Set<String>
    /// 本应用开始跟踪 Codex 的时间;此前已完成的历史 rollout 不进入待办
    public var trackingStartedAt: Date
    /// nil = 从未拖动过,使用默认右上角位置
    public var panelAnchor: PanelAnchor?

    public init(
        pinMode: PinMode = .todoOnly,
        completedSessionIDs: Set<String> = [],
        trackingStartedAt: Date = Date(),
        panelAnchor: PanelAnchor? = nil
    ) {
        self.pinMode = pinMode
        self.completedSessionIDs = completedSessionIDs
        self.trackingStartedAt = trackingStartedAt
        self.panelAnchor = panelAnchor
    }
}
