import AppKit
import SwiftUI

@main
struct AgentInboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 菜单栏入口 —— 系统原生菜单样式
        MenuBarExtra {
            MenuContentView(
                viewModel: appDelegate.viewModel,
                toggleWindow: {
                    appDelegate.togglePanel()
                }
            )
        } label: {
            Label("Agent Inbox", systemImage: appDelegate.viewModel.menuBarSystemImage)
        }
        .menuBarExtraStyle(.menu)

        // 设置窗口
        Settings {
            SettingsView(viewModel: appDelegate.viewModel)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = AppViewModel()
    private var panelController: FloatingPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 辅助应用:不显示在 Dock
        NSApp.setActivationPolicy(.accessory)

        // 启动顺序很重要:先加载持久化(含窗口锚点)→ 再创建浮窗(定位依赖锚点)→ 最后开 FSEvents 监听
        Task { @MainActor in
            await viewModel.prepare()

            let controller = FloatingPanelController(viewModel: viewModel)
            panelController = controller
            controller.show()

            viewModel.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stop()
    }

    func togglePanel() {
        panelController?.toggleVisibility()
    }
}
