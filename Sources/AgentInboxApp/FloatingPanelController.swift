import AppKit
import Combine
import AgentInboxCore
import OSLog
import SwiftUI

/// 浮窗位置重置通知(设置页「重置浮窗位置」触发)
extension Notification.Name {
    static let resetPanelPosition = Notification.Name("agent-inbox.resetPanelPosition")
}

/// 浮窗控制器 —— 无边框透明面板的生命周期、自适应尺寸与位置持久化
/// V4 核心机制:
/// 1. NSHostingView.sizingOptions = .preferredContentSize,SwiftUI 内容尺寸直接驱动窗口收放(胶囊⇄列表);
/// 2. 窗口 resize 后回钉「右上角锚点」,保证收放时视觉上固定在右上角不漂移;
/// 3. 用户拖动结束后把锚点写入 SQLite,跨启动恢复(补齐 task_plan 里未落地的窗口位置持久化)。
@MainActor
final class FloatingPanelController {
    private let panel: NSPanel
    private let viewModel: AppViewModel
    private var cancellables: Set<AnyCancellable> = []
    private var spaceReevaluationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "agent-inbox", category: "FloatingPanel")

    /// 当前窗口右上角锚点(屏幕坐标)
    private var anchor: NSPoint = .zero
    /// 程序化移动期间抑制 didMove 的锚点回写
    private var isProgrammaticMove = false
    /// 区分用户隐藏与其他应用占满屏幕时的临时抑制,保证离开全屏后自动恢复。
    private var isSuppressedForCoveredScreen = false

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel

        // 无边框 + 非激活式(不抢焦点)+ 全尺寸内容
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: DS.Metrics.listWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true // 面板任意处可拖动
        panel.backgroundColor = .clear // 透明窗口,圆角材质由 SwiftUI 绘制
        panel.isOpaque = false
        panel.hasShadow = true // 系统级阴影
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.animationBehavior = .none // 尺寸收放由 SwiftUI 动画驱动,窗口本身不做隐式动画

        // SwiftUI 内容:preferredContentSize 让内容理想尺寸驱动窗口大小
        let hostingView = NSHostingView(
            rootView: PanelRoot(viewModel: viewModel) { [weak self] in
                // 右键菜单「隐藏浮窗」
                self?.hide()
            }
        )
        hostingView.sizingOptions = [.preferredContentSize]
        panel.contentView = hostingView

        // 恢复锚点:持久化位置 → 默认右上角
        anchor = resolveInitialAnchor()
        repinToAnchor()

        observeWindowEvents()
        observePinning()

        logger.info("浮窗初始化完成,锚点 x=\(Int(self.anchor.x)) y=\(Int(self.anchor.y))")
    }

    // MARK: - 显示控制

    /// 显示浮窗(不抢占焦点)
    func show() {
        viewModel.setPanelVisible(true)
        let presentation = syncPinning()
        logger.info(
            "浮窗显示请求已同步: ordering=\(presentation.windowOrdering.rawValue, privacy: .public) suppressed=\(self.isSuppressedForCoveredScreen, privacy: .public)"
        )
    }

    /// 隐藏浮窗并同步菜单栏可见状态。
    private func hide() {
        viewModel.setPanelVisible(false)
        panel.orderOut(nil)
        isSuppressedForCoveredScreen = false
        logger.info("浮窗已隐藏")
    }

    /// 切换显示/隐藏
    func toggleVisibility() {
        if viewModel.isPanelVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - 锚点与定位

    /// 初始锚点:持久化值(有效时)→ 主屏右上角默认位
    private func resolveInitialAnchor() -> NSPoint {
        if let saved = viewModel.panelAnchor {
            let point = NSPoint(x: saved.topRightX, y: saved.topRightY)
            // 校验锚点仍落在某个屏幕的可见区域内(外接屏拔掉后防止浮窗丢失)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -8, dy: -8).contains(point) }) {
                logger.info("恢复持久化窗口位置")
                return point
            }
            logger.warning("持久化位置已不在任何屏幕内,回退默认位置")
        }
        return defaultAnchor()
    }

    /// 默认锚点:主屏可见区右上角内缩 16pt
    private func defaultAnchor() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 800, y: 600) }
        let frame = screen.visibleFrame
        return NSPoint(
            x: frame.maxX - DS.Metrics.screenMargin,
            y: frame.maxY - DS.Metrics.screenMargin
        )
    }

    /// 把窗口右上角钉回锚点(尺寸变化时保持右上角视觉固定)
    private func repinToAnchor() {
        isProgrammaticMove = true
        panel.setFrameOrigin(NSPoint(
            x: anchor.x - panel.frame.width,
            y: anchor.y - panel.frame.height
        ))
        isProgrammaticMove = false
    }

    // MARK: - 事件监听

    private func observeWindowEvents() {
        let center = NotificationCenter.default

        // 内容驱动的尺寸变化 → 回钉右上锚点(否则窗口会朝左下生长)
        center.publisher(for: NSWindow.didResizeNotification, object: panel)
            .sink { [weak self] _ in
                self?.repinToAnchor()
            }
            .store(in: &cancellables)

        // 用户拖动 → 更新锚点并防抖持久化(拖动过程 didMove 连发,只存停手后的终值)
        center.publisher(for: NSWindow.didMoveNotification, object: panel)
            .filter { [weak self] _ in self?.isProgrammaticMove == false }
            .handleEvents(receiveOutput: { [weak self] _ in
                guard let self else { return }
                // 实时更新内存锚点,保证拖动中途的 resize 也钉在新位置
                self.anchor = NSPoint(x: self.panel.frame.maxX, y: self.panel.frame.maxY)
            })
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.viewModel.savePanelAnchor(
                    PanelAnchor(topRightX: self.anchor.x, topRightY: self.anchor.y)
                )
                self.logger.info("窗口位置已持久化")
            }
            .store(in: &cancellables)

        // 设置页「重置浮窗位置」
        center.publisher(for: .resetPanelPosition)
            .sink { [weak self] _ in
                guard let self else { return }
                self.anchor = self.defaultAnchor()
                self.repinToAnchor()
                self.viewModel.savePanelAnchor(nil)
                self.show()
                self.logger.info("窗口位置已重置为默认右上角")
            }
            .store(in: &cancellables)

        // 原生全屏切换会改变 active Space;应用切换时也要立即重算临时抑制。
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
        .sink { [weak self] _ in
            self?.syncPinning()
            self?.scheduleSpaceReevaluation()
        }
        .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
        .sink { [weak self] _ in
            self?.syncPinning()
        }
        .store(in: &cancellables)
    }

    /// 监听快照/置顶模式变化,动态调整窗口层级
    private func observePinning() {
        viewModel.$snapshot
            .combineLatest(viewModel.$pinMode)
            .sink { [weak self] snapshot, pinMode in
                guard let self else { return }
                // @Published 在 willSet 阶段发值,必须使用 publisher 传入的新快照,
                // 不能回读 viewModel.snapshot,否则最后一个待办清空时会读到旧值。
                self.syncPinning(snapshot: snapshot, pinMode: pinMode)
            }
            .store(in: &cancellables)

        syncPinning()
    }

    /// 按当前配置与快照同步窗口层级及 Space 策略。show() 也显式调用一次,避免沿用旧状态。
    @discardableResult
    private func syncPinning(
        snapshot: AgentSnapshot? = nil,
        pinMode: PinMode? = nil
    ) -> PanelPresentation {
        let currentSnapshot = snapshot ?? viewModel.snapshot
        let currentPinMode = pinMode ?? viewModel.pinMode
        let presentation = currentPinMode.panelPresentation(for: currentSnapshot)
        applyPresentation(
            presentation,
            pinMode: currentPinMode,
            todoCount: currentSnapshot.todos.count,
            runningCount: currentSnapshot.running.count
        )
        return presentation
    }

    /// 置顶时跨 Space 覆盖全屏;非置顶时只跟随当前 Space。
    private func applyPresentation(
        _ presentation: PanelPresentation,
        pinMode: PinMode,
        todoCount: Int,
        runningCount: Int
    ) {
        let nextLevel: NSWindow.Level = presentation.shouldFloat ? .statusBar : .normal
        let nextCollectionBehavior: NSWindow.CollectionBehavior = switch presentation {
        case .normal:
            [.moveToActiveSpace]
        case .floatingAcrossFullscreen:
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        let levelChanged = panel.level != nextLevel
        let collectionBehaviorChanged = panel.collectionBehavior != nextCollectionBehavior

        guard levelChanged || collectionBehaviorChanged else {
            reconcilePanelVisibility(presentation)
            logger.info(
                "浮窗呈现策略已同步: mode=\(pinMode.rawValue, privacy: .public) presentation=\(presentation.rawValue, privacy: .public) ordering=\(presentation.windowOrdering.rawValue, privacy: .public) todo=\(todoCount, privacy: .public) running=\(runningCount, privacy: .public) level=\(Int(self.panel.level.rawValue), privacy: .public) collectionBehavior=\(Int(self.panel.collectionBehavior.rawValue), privacy: .public)"
            )
            return
        }

        panel.level = nextLevel
        panel.collectionBehavior = nextCollectionBehavior
        reconcilePanelVisibility(presentation)
        logger.info(
            "浮窗呈现策略已应用: mode=\(pinMode.rawValue, privacy: .public) presentation=\(presentation.rawValue, privacy: .public) ordering=\(presentation.windowOrdering.rawValue, privacy: .public) todo=\(todoCount, privacy: .public) running=\(runningCount, privacy: .public) level=\(Int(nextLevel.rawValue), privacy: .public) collectionBehavior=\(Int(nextCollectionBehavior.rawValue), privacy: .public)"
        )
    }

    /// 普通态只按 AppKit 标准顺序显示;只有置顶策略可以绕过前台应用强制置前。
    private func orderPanel(_ ordering: PanelWindowOrdering) {
        switch ordering {
        case .front:
            panel.orderFront(nil)
        case .frontRegardless:
            panel.orderFrontRegardless()
        }
    }

    /// 应用置顶策略与前台窗口覆盖状态,不会把临时抑制写成用户隐藏。
    private func reconcilePanelVisibility(_ presentation: PanelPresentation) {
        let frontmostWindowCoversScreen = activeFrontmostWindowCoversScreen()
        let shouldSuppress = presentation.shouldSuppress(
            whenFrontmostWindowCoversScreen: frontmostWindowCoversScreen
        )

        if shouldSuppress {
            panel.orderOut(nil)
        } else if viewModel.isPanelVisible {
            orderPanel(presentation.windowOrdering)
        }

        guard shouldSuppress != isSuppressedForCoveredScreen else { return }
        isSuppressedForCoveredScreen = shouldSuppress
        logger.info(
            "浮窗全屏抑制已变更: suppressed=\(shouldSuppress, privacy: .public) presentation=\(presentation.rawValue, privacy: .public) frontmostCoversScreen=\(frontmostWindowCoversScreen, privacy: .public)"
        )
    }

    /// 无需辅助功能权限:只用前台进程、窗口层级和公开 bounds 判断窗口是否占满某块屏幕。
    private func activeFrontmostWindowCoversScreen() -> Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        let screenSizes = NSScreen.screens.map { $0.frame.size }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] ?? []

        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t)
                    == frontmostApplication.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
                  let width = bounds["Width"]?.doubleValue,
                  let height = bounds["Height"]?.doubleValue else {
                return false
            }

            return screenSizes.contains { screenSize in
                // 原生全屏窗口可能为系统菜单栏保留少量高度;90% 阈值也覆盖系统缩放最大化窗口。
                width >= screenSize.width * 0.9 && height >= screenSize.height * 0.9
            }
        }
    }

    /// Space 通知早于全屏动画结束;延迟复核最终窗口尺寸,避免进入/退出状态卡在过渡值。
    private func scheduleSpaceReevaluation() {
        spaceReevaluationTask?.cancel()
        spaceReevaluationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.syncPinning()
        }
    }
}
