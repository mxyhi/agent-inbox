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
            MenuBarLabel(viewModel: appDelegate.viewModel)
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

        // 启动顺序很重要:先加载持久化 → 开监听并完成首扫 → 再创建浮窗(定位/置顶依赖状态)
        Task { @MainActor in
            await viewModel.prepare()
            await viewModel.start()

            let controller = FloatingPanelController(viewModel: viewModel)
            panelController = controller
            controller.show()

        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stop()
    }

    func togglePanel() {
        panelController?.toggleVisibility()
    }
}

/// 菜单栏入口标签必须直接观察 ViewModel,否则 MenuBarExtra label 可能不会跟随 snapshot 立即重绘。
private struct MenuBarLabel: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Label("Agent Inbox", systemImage: viewModel.menuBarSystemImage)
    }
}
