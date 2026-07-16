import Foundation

/// AppKit 窗口排序动作,与置顶策略一起计算,避免调用方再次强制置前。
public enum PanelWindowOrdering: String, Equatable, Sendable {
    case front
    case frontRegardless
}

/// 浮窗在普通 Space 与全屏 Space 中的统一呈现策略。
public enum PanelPresentation: String, Equatable, Sendable {
    case normal
    case floatingAcrossFullscreen

    public var shouldFloat: Bool {
        self == .floatingAcrossFullscreen
    }

    public var windowOrdering: PanelWindowOrdering {
        switch self {
        case .normal:
            .front
        case .floatingAcrossFullscreen:
            .frontRegardless
        }
    }

    /// 普通态不覆盖占满屏幕的前台应用;置顶态保持跨全屏可见。
    public func shouldSuppress(whenFrontmostWindowCoversScreen: Bool) -> Bool {
        self == .normal && whenFrontmostWindowCoversScreen
    }
}

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

    /// 同一个置顶判定必须同时控制窗口层级与全屏 Space 参与。
    public func panelPresentation(for snapshot: AgentSnapshot) -> PanelPresentation {
        shouldFloat(for: snapshot) ? .floatingAcrossFullscreen : .normal
    }
}

/// 会话源:会话数据来自哪一类 agent 工具。
public enum AgentProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case grok

    public var id: String { rawValue }

    /// UI 标签文案
    public var label: String {
        switch self {
        case .codex:
            "Codex"
        case .grok:
            "Grok"
        }
    }
}

/// 会话身份工具:源原生 id 保持不变,完成集合/ForEach 使用复合键。
public enum SessionIdentity {
    /// `provider:sessionID`,保证跨源唯一。
    public static func key(provider: AgentProvider, sessionID: String) -> String {
        "\(provider.rawValue):\(sessionID)"
    }

    /// 读库归一:旧 completed 无前缀 id 视为 Codex。
    public static func normalizeCompletedID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let separator = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[..<separator])
            let rest = String(trimmed[trimmed.index(after: separator)...])
            if AgentProvider(rawValue: prefix) != nil, !rest.isEmpty {
                return trimmed
            }
        }

        return key(provider: .codex, sessionID: trimmed)
    }
}

/// Turn 生命周期状态(跨源统一)。
/// Codex 来自 rollout 尾部 lifecycle event;Grok 由 events.jsonl + 进程存活合成。
public enum TurnLifecycleState: String, Codable, Equatable, Sendable {
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
    case equals

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .contains:
            "包含"
        case .equals:
            "等于"
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

    public func matches(_ summary: SessionSummary) -> Bool {
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
        case .equals:
            return value.compare(trimmedPattern, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}

/// 跨源会话摘要。
/// Codex:rollout head/tail;Grok:summary.json + events + 进程存活。
public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    /// 会话源
    public let provider: AgentProvider
    /// 源原生会话 id(Codex/Grok 均保持原格式,不加前缀)
    public let sessionID: String
    public let filePath: String
    /// 会话工作目录,UI 用它展示项目名
    public let cwd: String?
    /// 会话启动时间,UI 用它计算运行时长
    public let startedAt: Date?
    /// 内容最近变更时间,用于活跃度/stale 判定
    public let modifiedAt: Date
    /// 最近 turn 生命周期;aborted/rolledBack/unknown 不进运行中/待办
    public let lifecycleState: TurnLifecycleState
    /// 完成时间;nil 表示尚未以「可确认完成」形态结束
    public let taskCompletedAt: Date?
    /// 焦点卡「答」:agent 最后交付摘要
    public let lastAgentMessage: String?
    /// 焦点卡「问」:首个用户提示词(已清洗截断);nil = 未捕获
    public let firstPrompt: String?

    public init(
        provider: AgentProvider = .codex,
        sessionID: String,
        filePath: String,
        cwd: String?,
        startedAt: Date?,
        modifiedAt: Date,
        lifecycleState: TurnLifecycleState? = nil,
        taskCompletedAt: Date?,
        lastAgentMessage: String?,
        firstPrompt: String? = nil
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.filePath = filePath
        self.cwd = cwd
        self.startedAt = startedAt
        self.modifiedAt = modifiedAt
        self.lifecycleState = lifecycleState ?? (taskCompletedAt == nil ? .running : .completed)
        self.taskCompletedAt = taskCompletedAt
        self.lastAgentMessage = lastAgentMessage
        self.firstPrompt = firstPrompt
    }

    /// ForEach / 完成集合唯一键:`provider:sessionID`
    public var id: String {
        SessionIdentity.key(provider: provider, sessionID: sessionID)
    }

    public var isTaskComplete: Bool {
        taskCompletedAt != nil
    }

    /// 项目名:cwd 最后一段;无 cwd 时退化为路径末段
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
    public let todos: [SessionSummary]
    /// 运行中的会话,最近活跃的排前面
    public let running: [SessionSummary]
    /// 历史上是否手动完成过任务(区分「从未有任务」与「全部处理完」)
    public let hasCompletedHistory: Bool

    public init(
        todos: [SessionSummary],
        running: [SessionSummary],
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

    /// 只把已观察为运行中、随后进入待办的同一会话视为新待办。
    /// 直接从空快照发现的历史待办不会触发启动通知。
    public func newTodos(comparedTo previous: AgentSnapshot) -> [SessionSummary] {
        let previouslyRunningIDs = Set(previous.running.map(\.id))
        return todos.filter { previouslyRunningIDs.contains($0.id) }
    }
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

/// 会话打开方式
public enum OpenSessionMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case finder       // Finder 中打开目录（默认）
    case terminal     // Terminal.app 中打开
    case vscode       // VS Code 中打开（需已安装 code 命令）
    case custom       // 自定义 shell 命令

    public var id: String { rawValue }

    /// 设置界面展示名称
    public var label: String {
        switch self {
        case .finder:
            "Finder"
        case .terminal:
            "终端"
        case .vscode:
            "VS Code"
        case .custom:
            "自定义命令"
        }
    }

    /// 方式说明（设置界面副标题）
    public var description: String {
        switch self {
        case .finder:
            "在 Finder 中打开工作目录"
        case .terminal:
            "在终端中打开工作目录"
        case .vscode:
            "使用 VS Code 打开工作目录"
        case .custom:
            "执行自定义 shell 命令"
        }
    }
}

/// 会话打开配置
public struct OpenSessionConfig: Codable, Equatable, Sendable {
    /// 打开方式
    public var method: OpenSessionMethod
    /// 自定义命令模板（仅当 method == .custom 时生效）
    /// 支持变量：$session_id, $cwd, $file_path, $project_name
    public var customCommand: String

    public init(
        method: OpenSessionMethod = .finder,
        customCommand: String = ""
    ) {
        self.method = method
        self.customCommand = customCommand
    }

    /// 支持的模板变量列表（用于 UI 提示）
    public static let supportedVariables: [(name: String, description: String)] = [
        ("$session_id", "源原生会话 ID"),
        ("$provider", "会话源(codex/grok)"),
        ("$cwd", "工作目录路径"),
        ("$file_path", "会话文件或目录路径"),
        ("$project_name", "项目名称")
    ]

    /// 示例命令模板
    public static let exampleCommands: [String] = [
        "open -a Terminal \"$cwd\"",
        "code \"$cwd\"",
        "cursor \"$cwd\"",
        "echo \"Opening session $session_id at $cwd\""
    ]
}

/// 自动更新网络代理配置。空地址表示不启用;非空地址必须是带协议、主机、端口的代理 URL。
public struct NetworkProxyConfig: Codable, Equatable, Sendable {
    public var urlString: String

    public init(
        urlString: String = ""
    ) {
        self.urlString = urlString
    }

    /// 去除输入框空白;持久化和网络层都使用这份规范值。
    public var normalizedURLString: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool {
        normalizedURLString.isEmpty
    }

    /// 只有配置完整时才向 URLSession 注入代理,避免半截配置破坏更新检查。
    public var isUsable: Bool {
        parsedURL != nil
    }

    public var parsedURL: URLComponents? {
        guard !normalizedURLString.isEmpty,
              var components = URLComponents(string: normalizedURLString),
              let scheme = components.scheme?.lowercased(),
              Self.supportedSchemes.contains(scheme),
              let host = components.host,
              !host.isEmpty,
              let port = components.port,
              (1...65_535).contains(port) else {
            return nil
        }

        components.scheme = scheme
        return components
    }

    /// 保存前统一修剪 URL,不保留 UI 输入里的首尾空白。
    public var normalized: NetworkProxyConfig {
        NetworkProxyConfig(urlString: normalizedURLString)
    }

    public static let supportedSchemes: Set<String> = [
        "http",
        "https",
        "socks",
        "socks4",
        "socks4a",
        "socks5",
        "socks5h"
    ]
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
    /// 会话打开配置
    public var openSessionConfig: OpenSessionConfig
    /// 自动更新网络代理配置
    public var updateProxyConfig: NetworkProxyConfig

    public init(
        pinMode: PinMode = .todoOnly,
        completedSessionIDs: Set<String> = [],
        trackingStartedAt: Date = Date(),
        panelAnchor: PanelAnchor? = nil,
        promptFilterRules: [PromptFilterRule] = [],
        openSessionConfig: OpenSessionConfig = OpenSessionConfig(),
        updateProxyConfig: NetworkProxyConfig = NetworkProxyConfig()
    ) {
        self.pinMode = pinMode
        self.completedSessionIDs = completedSessionIDs
        self.trackingStartedAt = trackingStartedAt
        self.panelAnchor = panelAnchor
        self.promptFilterRules = promptFilterRules
        self.openSessionConfig = openSessionConfig
        self.updateProxyConfig = updateProxyConfig
    }
}
