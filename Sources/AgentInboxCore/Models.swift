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

/// prompt 过滤字段。首版只支持 firstPrompt,后续有真实 metadata 再扩展。
public enum PromptFilterField: String, Codable, CaseIterable, Sendable, Identifiable {
    case firstPrompt

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .firstPrompt:
            "首个提示词"
        }
    }
}

/// firstPrompt 过滤匹配方式。
public enum PromptFilterMatchType: String, Codable, CaseIterable, Sendable, Identifiable {
    case contains
    case regex

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .contains:
            "包含"
        case .regex:
            "正则"
        }
    }
}

/// 过滤命中后的动作。首版只隐藏待办,不把会话标记完成。
public enum PromptFilterAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case hideFromTodos

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hideFromTodos:
            "不进入待办"
        }
    }
}

/// 用户配置的 firstPrompt 过滤规则。
public struct PromptFilterRule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var isEnabled: Bool
    public var field: PromptFilterField
    public var matchType: PromptFilterMatchType
    public var pattern: String
    public var action: PromptFilterAction
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        isEnabled: Bool = true,
        field: PromptFilterField = .firstPrompt,
        matchType: PromptFilterMatchType = .contains,
        pattern: String,
        action: PromptFilterAction = .hideFromTodos,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.field = field
        self.matchType = matchType
        self.pattern = pattern
        self.action = action
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func matches(_ summary: CodexSessionSummary) -> Bool {
        guard isEnabled, action == .hideFromTodos else { return false }

        let value = switch field {
        case .firstPrompt:
            summary.firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !value.isEmpty else { return false }

        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return false }

        switch matchType {
        case .contains:
            return value.range(of: trimmedPattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .regex:
            guard let regex = try? NSRegularExpression(
                pattern: trimmedPattern,
                options: [.caseInsensitive]
            ) else {
                return false
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, options: [], range: range) != nil
        }
    }
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
    /// task_complete.last_agent_message,焦点卡「答」段:Codex 最后交付了什么
    public let lastAgentMessage: String?
    /// 会话首个用户提示词(rollout 首个 event_msg/user_message,已跳过注入的
    /// developer/环境上下文;取首个非空行并截断)。焦点卡「问」段展示这活儿的由来;
    /// nil = head 窗口内未捕获到用户输入。
    public let firstPrompt: String?

    public init(
        id: String,
        filePath: String,
        cwd: String?,
        startedAt: Date?,
        modifiedAt: Date,
        lifecycleState: CodexTurnLifecycleState? = nil,
        taskCompletedAt: Date?,
        lastAgentMessage: String?,
        firstPrompt: String? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.cwd = cwd
        self.startedAt = startedAt
        self.modifiedAt = modifiedAt
        self.lifecycleState = lifecycleState ?? (taskCompletedAt == nil ? .running : .completed)
        self.taskCompletedAt = taskCompletedAt
        self.lastAgentMessage = lastAgentMessage
        self.firstPrompt = firstPrompt
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
    /// 用户配置的 firstPrompt 过滤规则;命中后不进入待办,但不写 completed_sessions。
    public var promptFilterRules: [PromptFilterRule]

    public init(
        pinMode: PinMode = .todoOnly,
        completedSessionIDs: Set<String> = [],
        trackingStartedAt: Date = Date(),
        panelAnchor: PanelAnchor? = nil,
        promptFilterRules: [PromptFilterRule] = []
    ) {
        self.pinMode = pinMode
        self.completedSessionIDs = completedSessionIDs
        self.trackingStartedAt = trackingStartedAt
        self.panelAnchor = panelAnchor
        self.promptFilterRules = promptFilterRules
    }
}
