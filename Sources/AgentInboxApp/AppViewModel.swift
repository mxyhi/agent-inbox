import AppKit
import Foundation
import AgentInboxCore
import OSLog

/// 主 ViewModel —— 串联「后台扫描 → 快照解析 → UI 发布」
/// 扫描跑在 CompositeSessionMonitor(Codex+Grok) 上,主线程零文件 IO。
@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var snapshot: AgentSnapshot = .empty
    @Published private(set) var isPanelVisible = false
    @Published private(set) var promptFilterRules: [PromptFilterRule] = []
    @Published var pinMode: PinMode = .todoOnly
    @Published var openSessionConfig: OpenSessionConfig = OpenSessionConfig()
    @Published var updateProxyConfig: NetworkProxyConfig = NetworkProxyConfig()

    private let monitor: CompositeSessionMonitor
    private let resolver: AgentStatusResolver
    private let stateStore: StateStore
    private let executor: OpenSessionExecutor
    private let notificationController: UserNotificationController
    private let logger = Logger(subsystem: "agent-inbox", category: "AppViewModel")
    private var persistedState = PersistedState()
    private var reconcileTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var watcher: SessionsWatcher?
    private var pendingChangedPaths: Set<String> = []
    private var hasLoadedInitialSnapshot = false

    init(
        monitor: CompositeSessionMonitor = CompositeSessionMonitor(),
        resolver: AgentStatusResolver = AgentStatusResolver(),
        stateStore: StateStore = StateStore(),
        executor: OpenSessionExecutor = OpenSessionExecutor(),
        notificationController: UserNotificationController = UserNotificationController()
    ) {
        self.monitor = monitor
        self.resolver = resolver
        self.stateStore = stateStore
        self.executor = executor
        self.notificationController = notificationController
    }

    // MARK: - 生命周期

    /// 一次性加载持久化状态(必须在浮窗定位前完成,因为要恢复窗口锚点)
    func prepare() async {
        persistedState = await stateStore.load()
        pinMode = persistedState.pinMode
        promptFilterRules = persistedState.promptFilterRules
        openSessionConfig = persistedState.openSessionConfig
        updateProxyConfig = persistedState.updateProxyConfig
        logger.info(
            "持久化状态已加载,pinMode=\(self.pinMode.rawValue, privacy: .public),filterRules=\(self.promptFilterRules.count),openMethod=\(self.openSessionConfig.method.rawValue, privacy: .public),updateProxySet=\(!self.updateProxyConfig.isEmpty, privacy: .public)"
        )
    }

    /// 启动首扫:在浮窗显示前建立快照,避免条件置顶模式用空快照先降级为普通窗口。
    func loadInitialSnapshot() async {
        guard !hasLoadedInitialSnapshot else { return }

        await refresh()
        hasLoadedInitialSnapshot = true
        logger.info("启动初始快照已加载")
    }

    /// 启动 FSEvents 监听并完成首扫:事件驱动刷新,低频 full scan 只做兜底校准
    func start() async {
        guard reconcileTask == nil, watcher == nil else { return }

        watcher = SessionsWatcher(roots: monitor.watchRoots) { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.scheduleIncrementalRefresh(paths: paths)
            }
        }
        watcher?.start()

        await loadInitialSnapshot()

        reconcileTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
        }
        logger.info("FSEvents 监听已启动,低频兜底扫描已启用")
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        pendingChangedPaths.removeAll()
        logger.info("FSEvents 监听已停止")
    }

    // MARK: - 用户操作

    /// 完成单个待办 —— 乐观更新:立即从快照剔除,点击反馈零延迟
    func completeTodo(id: String) {
        guard snapshot.todos.contains(where: { $0.id == id }) else { return }

        persistedState.completedSessionIDs.insert(id)
        snapshot = AgentSnapshot(
            todos: snapshot.todos.filter { $0.id != id },
            running: snapshot.running,
            hasCompletedHistory: true
        )
        logger.info("待办已完成: \(id, privacy: .public)")

        Task {
            await stateStore.save(persistedState)
        }
    }

    /// 打开会话工作目录 —— 根据配置使用不同方式打开
    func openSession(id: String) {
        guard let session = snapshot.todos.first(where: { $0.id == id })
            ?? snapshot.running.first(where: { $0.id == id }) else {
            logger.warning("openSession 未找到会话: \(id, privacy: .public)")
            notificationController.show(title: "打开失败", message: "未找到会话 \(id)")
            return
        }

        do {
            try executor.execute(session: session, config: openSessionConfig)
            logger.info("成功打开会话: \(id, privacy: .public), method=\(self.openSessionConfig.method.rawValue, privacy: .public)")
        } catch {
            logger.error("打开会话失败: \(String(describing: error), privacy: .public)")
            notificationController.show(title: "打开会话失败", message: error.localizedDescription)
        }
    }

    /// 一键完成全部待办(右键菜单/菜单栏)
    func completeAllTodos() {
        guard snapshot.hasTodo else { return }

        for todo in snapshot.todos {
            persistedState.completedSessionIDs.insert(todo.id)
        }
        let count = snapshot.todos.count
        snapshot = AgentSnapshot(
            todos: [],
            running: snapshot.running,
            hasCompletedHistory: true
        )
        logger.info("已批量完成 \(count) 个待办")

        Task {
            await stateStore.save(persistedState)
        }
    }

    func refreshNow() {
        Task {
            await refresh()
        }
    }

    func setPinMode(_ mode: PinMode) {
        guard pinMode != mode else { return }

        pinMode = mode
        persistedState.pinMode = mode
        logger.info("置顶模式变更: \(mode.rawValue, privacy: .public)")

        Task {
            await stateStore.save(persistedState)
        }
    }

    func setOpenSessionConfig(_ config: OpenSessionConfig) {
        guard openSessionConfig != config else { return }

        openSessionConfig = config
        persistedState.openSessionConfig = config
        logger.info("会话打开配置变更: method=\(config.method.rawValue, privacy: .public)")

        Task {
            await stateStore.save(persistedState)
        }
    }

    func setUpdateProxyConfig(_ config: NetworkProxyConfig) {
        let normalized = config.normalized
        guard updateProxyConfig != normalized else { return }

        updateProxyConfig = normalized
        persistedState.updateProxyConfig = normalized
        logger.info(
            "更新代理配置变更: urlSet=\(!normalized.isEmpty, privacy: .public),usable=\(normalized.isUsable, privacy: .public)"
        )

        Task {
            await stateStore.save(persistedState)
        }
    }

    func addPromptFilterRule(pattern: String, matchType: PromptFilterMatchType) {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return }

        let now = Date()
        let rule = PromptFilterRule(
            matchType: matchType,
            pattern: trimmedPattern,
            createdAt: now,
            updatedAt: now
        )
        persistedState.promptFilterRules.append(rule)
        promptFilterRules = persistedState.promptFilterRules
        filterCurrentSnapshot()
        logger.info("新增 firstPrompt 过滤规则: \(rule.id, privacy: .public)")

        Task {
            await stateStore.save(persistedState)
        }
    }

    func addPromptFilterRule(from sessionID: String) {
        guard let session = snapshot.todos.first(where: { $0.id == sessionID }),
              let prompt = session.firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            logger.warning("无法从会话创建 firstPrompt 过滤规则: \(sessionID, privacy: .public)")
            return
        }

        addPromptFilterRule(
            pattern: prompt,
            matchType: .contains
        )
    }

    func setPromptFilterRuleEnabled(id: String, isEnabled: Bool) {
        guard let index = persistedState.promptFilterRules.firstIndex(where: { $0.id == id }) else { return }
        guard persistedState.promptFilterRules[index].isEnabled != isEnabled else { return }

        persistedState.promptFilterRules[index].isEnabled = isEnabled
        persistedState.promptFilterRules[index].updatedAt = Date()
        promptFilterRules = persistedState.promptFilterRules
        filterCurrentSnapshot()
        logger.info("过滤规则启用状态变更: \(id, privacy: .public), enabled=\(isEnabled)")

        Task {
            await stateStore.save(persistedState)
            await refresh()
        }
    }

    func updatePromptFilterRule(
        id: String,
        pattern: String,
        matchType: PromptFilterMatchType
    ) {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return }
        guard let index = persistedState.promptFilterRules.firstIndex(where: { $0.id == id }) else { return }

        persistedState.promptFilterRules[index].pattern = trimmedPattern
        persistedState.promptFilterRules[index].matchType = matchType
        persistedState.promptFilterRules[index].updatedAt = Date()
        promptFilterRules = persistedState.promptFilterRules
        filterCurrentSnapshot()
        logger.info("更新 firstPrompt 过滤规则: \(id, privacy: .public)")

        Task {
            await stateStore.save(persistedState)
            await refresh()
        }
    }

    func deletePromptFilterRule(id: String) {
        let originalCount = persistedState.promptFilterRules.count
        persistedState.promptFilterRules.removeAll { $0.id == id }
        guard persistedState.promptFilterRules.count != originalCount else { return }

        promptFilterRules = persistedState.promptFilterRules
        logger.info("删除 firstPrompt 过滤规则: \(id, privacy: .public)")

        Task {
            await stateStore.save(persistedState)
            await refresh()
        }
    }

    /// 浮窗显隐状态由 AppKit 控制器回写,菜单项据此展示下一步动作。
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }

        isPanelVisible = visible
        logger.info("浮窗可见状态变更: \(visible, privacy: .public)")
    }

    // MARK: - 浮窗位置持久化

    /// 当前已保存的窗口锚点(nil = 使用默认右上角)
    var panelAnchor: PanelAnchor? {
        persistedState.panelAnchor
    }

    /// 保存窗口锚点(用户拖动结束后由 FloatingPanelController 调用)
    func savePanelAnchor(_ anchor: PanelAnchor?) {
        guard persistedState.panelAnchor != anchor else { return }

        persistedState.panelAnchor = anchor
        logger.debug("窗口锚点已更新")

        Task {
            await stateStore.save(persistedState)
        }
    }

    // MARK: - 派生状态

    /// 浮窗是否应当置顶(由置顶模式 × 快照共同决定)
    var shouldFloatWindow: Bool {
        pinMode.shouldFloat(for: snapshot)
    }

    /// 菜单栏图标 —— 待办 > 运行中 > 完成历史 > 空闲
    var menuBarSystemImage: String {
        if snapshot.hasTodo {
            "exclamationmark.circle.fill"
        } else if snapshot.isActive {
            "bolt.circle.fill"
        } else if snapshot.hasCompletedHistory {
            "checkmark.circle"
        } else {
            "circle.dotted"
        }
    }

    /// 菜单栏摘要行,如 "2 个待办 · 1 个运行中"
    var menuSummary: String {
        var parts: [String] = []
        if snapshot.hasTodo {
            parts.append("\(snapshot.todos.count) 个待办")
        }
        if snapshot.isActive {
            parts.append("\(snapshot.running.count) 个运行中")
        }
        if parts.isEmpty {
            return snapshot.hasCompletedHistory ? "全部完成" : "暂无 Agent 任务"
        }
        return parts.joined(separator: " · ")
    }

    /// 菜单栏按钮标题:显示当前可执行动作,避免“显示/隐藏”二义性。
    var panelVisibilityMenuTitle: String {
        isPanelVisible ? "隐藏浮窗" : "显示浮窗"
    }

    // MARK: - 内部

    /// 扫描 → 解析 → 发布(仅在快照变化时触发 UI 更新)
    private func refresh() async {
        let summaries = await monitor.scan()
        publish(summaries: summaries)
    }

    private func refreshChangedPaths(_ paths: [String]) async {
        let summaries = await monitor.scanChangedPaths(paths)
        publish(summaries: summaries)
    }

    private func scheduleIncrementalRefresh(paths: [String]) {
        pendingChangedPaths.formUnion(paths)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let paths = Array(self.pendingChangedPaths)
            self.pendingChangedPaths.removeAll()
            await self.refreshChangedPaths(paths)
        }
    }

    private func publish(summaries: [SessionSummary]) {
        let next = resolver.resolve(
            summaries: summaries,
            completedSessionIDs: persistedState.completedSessionIDs,
            promptFilterRules: persistedState.promptFilterRules,
            trackingStartedAt: persistedState.trackingStartedAt
        )

        if next != snapshot {
            let newTodos = next.newTodos(comparedTo: snapshot)
            logger.info("快照变化: 待办 \(next.todos.count) · 运行 \(next.running.count)")
            snapshot = next
            notifyNewTodos(newTodos)
        }
    }

    /// 同一轮多个完成事件合并为一条系统通知，避免连续播放多次声音。
    private func notifyNewTodos(_ todos: [SessionSummary]) {
        guard !todos.isEmpty else { return }

        let title = todos.count == 1 ? "有新待办" : "有 \(todos.count) 个新待办"
        let message = if let todo = todos.first, todos.count == 1 {
            "\(todo.projectName) 的 Agent 会话已完成，等待处理"
        } else {
            "\(todos.count) 个 Agent 会话已完成，等待处理"
        }
        notificationController.show(
            title: title,
            message: message,
            threadIdentifier: "agent-inbox-todos"
        )
        logger.info("新待办通知已请求: count=\(todos.count)")
    }

    private func filterCurrentSnapshot() {
        let filteredTodos = snapshot.todos.filter { session in
            !persistedState.promptFilterRules.contains { $0.matches(session) }
        }
        guard filteredTodos.count != snapshot.todos.count else { return }

        snapshot = AgentSnapshot(
            todos: filteredTodos,
            running: snapshot.running,
            hasCompletedHistory: snapshot.hasCompletedHistory
        )
    }
}
