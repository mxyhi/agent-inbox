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
    private let logger = Logger(subsystem: "agent-inbox", category: "FloatingPanel")

    /// 当前窗口右上角锚点(屏幕坐标)
    private var anchor: NSPoint = .zero
    /// 程序化移动期间抑制 didMove 的锚点回写
    private var isProgrammaticMove = false

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
        panel.collectionBehavior = [.canJoinAllSpaces]
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
        syncPinning()
        panel.orderFrontRegardless()
        viewModel.setPanelVisible(true)
        logger.info("浮窗已显示")
    }

    /// 隐藏浮窗并同步菜单栏可见状态。
    private func hide() {
        panel.orderOut(nil)
        viewModel.setPanelVisible(false)
        logger.info("浮窗已隐藏")
    }

    /// 切换显示/隐藏
    func toggleVisibility() {
        if panel.isVisible {
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
    }

    /// 监听快照/置顶模式变化,动态调整窗口层级
    private func observePinning() {
        viewModel.$snapshot
            .combineLatest(viewModel.$pinMode, viewModel.$fullscreenOverlayMode)
            .sink { [weak self] snapshot, pinMode, fullscreenOverlayMode in
                guard let self else { return }
                // @Published 在 willSet 阶段发值,必须使用 publisher 传入的新快照,
                // 不能回读 viewModel.snapshot,否则最后一个待办清空时会读到旧值。
                self.syncPinning(
                    snapshot: snapshot,
                    pinMode: pinMode,
                    fullscreenOverlayMode: fullscreenOverlayMode
                )
            }
            .store(in: &cancellables)

        syncPinning()
    }

    /// 按当前配置与快照同步窗口层级。show() 也显式调用一次,避免窗口重新显示时沿用旧 level。
    private func syncPinning(
        snapshot: AgentSnapshot? = nil,
        pinMode: PinMode? = nil,
        fullscreenOverlayMode: FullscreenOverlayMode? = nil
    ) {
        let currentSnapshot = snapshot ?? viewModel.snapshot
        let currentPinMode = pinMode ?? viewModel.pinMode
        let currentFullscreenOverlayMode = fullscreenOverlayMode ?? viewModel.fullscreenOverlayMode
        let shouldFloat = currentPinMode.shouldFloat(for: currentSnapshot)
        applyPinning(
            shouldFloat: shouldFloat,
            shouldCoverFullscreen: currentFullscreenOverlayMode.shouldCoverFullscreen(shouldFloat: shouldFloat),
            pinMode: currentPinMode,
            fullscreenOverlayMode: currentFullscreenOverlayMode,
            todoCount: currentSnapshot.todos.count,
            runningCount: currentSnapshot.running.count
        )
    }

    /// 应用置顶态:`.statusBar` 管普通窗口层级,collectionBehavior 单独管全屏 Space 覆盖。
    private func applyPinning(
        shouldFloat: Bool,
        shouldCoverFullscreen: Bool,
        pinMode: PinMode,
        fullscreenOverlayMode: FullscreenOverlayMode,
        todoCount: Int,
        runningCount: Int
    ) {
        let nextLevel: NSWindow.Level = shouldFloat ? .statusBar : .normal
        let nextCollectionBehavior: NSWindow.CollectionBehavior = shouldCoverFullscreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces]
        let levelChanged = panel.level != nextLevel
        let collectionBehaviorChanged = panel.collectionBehavior != nextCollectionBehavior

        guard levelChanged || collectionBehaviorChanged else {
            if shouldFloat, panel.isVisible {
                panel.orderFrontRegardless()
            }
            logger.info(
                "浮窗置顶状态已同步: mode=\(pinMode.rawValue, privacy: .public) fullscreenOverlay=\(fullscreenOverlayMode.rawValue, privacy: .public) todo=\(todoCount, privacy: .public) running=\(runningCount, privacy: .public) shouldFloat=\(shouldFloat, privacy: .public) coverFullscreen=\(shouldCoverFullscreen, privacy: .public) level=\(Int(self.panel.level.rawValue), privacy: .public)"
            )
            return
        }

        panel.level = nextLevel
        panel.collectionBehavior = nextCollectionBehavior
        if shouldFloat, panel.isVisible {
            panel.orderFrontRegardless()
        }
        logger.info(
            "浮窗置顶状态已应用: mode=\(pinMode.rawValue, privacy: .public) fullscreenOverlay=\(fullscreenOverlayMode.rawValue, privacy: .public) todo=\(todoCount, privacy: .public) running=\(runningCount, privacy: .public) shouldFloat=\(shouldFloat, privacy: .public) coverFullscreen=\(shouldCoverFullscreen, privacy: .public) level=\(Int(nextLevel.rawValue), privacy: .public)"
        )
    }
}
