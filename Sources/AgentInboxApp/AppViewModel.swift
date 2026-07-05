import Foundation
import AgentInboxCore
import OSLog

/// 主 ViewModel —— 串联「后台扫描 → 快照解析 → UI 发布」
/// V4:AgentDisplayState 单焦点状态机已废弃,改为 AgentSnapshot 列表快照;
/// 扫描跑在 CodexSessionMonitor actor 上,主线程零文件 IO。
@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var snapshot: AgentSnapshot = .empty
    @Published private(set) var isPanelVisible = false
    @Published var pinMode: PinMode = .todoOnly

    private let monitor: CodexSessionMonitor
    private let resolver: CodexStatusResolver
    private let stateStore: StateStore
    private let logger = Logger(subsystem: "agent-inbox", category: "AppViewModel")
    private var persistedState = PersistedState()
    private var reconcileTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var watcher: CodexSessionsWatcher?
    private var pendingChangedPaths: Set<String> = []

    init(
        monitor: CodexSessionMonitor = CodexSessionMonitor(),
        resolver: CodexStatusResolver = CodexStatusResolver(),
        stateStore: StateStore = StateStore()
    ) {
        self.monitor = monitor
        self.resolver = resolver
        self.stateStore = stateStore
    }

    // MARK: - 生命周期

    /// 一次性加载持久化状态(必须在浮窗定位前完成,因为要恢复窗口锚点)
    func prepare() async {
        persistedState = await stateStore.load()
        pinMode = persistedState.pinMode
        logger.info("持久化状态已加载,pinMode=\(self.pinMode.rawValue, privacy: .public)")
    }

    /// 启动 FSEvents 监听:事件驱动刷新,低频 full scan 只做兜底校准
    func start() {
        guard reconcileTask == nil, watcher == nil else { return }

        watcher = CodexSessionsWatcher(root: monitor.sessionsRoot) { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.scheduleIncrementalRefresh(paths: paths)
            }
        }
        watcher?.start()

        reconcileTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
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
            return snapshot.hasCompletedHistory ? "全部完成" : "暂无 Codex 任务"
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

    private func publish(summaries: [CodexSessionSummary]) {
        let next = resolver.resolve(
            summaries: summaries,
            completedSessionIDs: persistedState.completedSessionIDs,
            trackingStartedAt: persistedState.trackingStartedAt
        )

        if next != snapshot {
            logger.info("快照变化: 待办 \(next.todos.count) · 运行 \(next.running.count)")
            snapshot = next
        }
    }
}
