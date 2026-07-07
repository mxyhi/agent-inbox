import AppKit
import AgentInboxCore
import SwiftUI

// MARK: - 菜单栏内容

/// 菜单栏下拉菜单 —— 保持系统原生交互
/// V4:摘要行显示「N 个待办 · M 个运行中」,待办可直接在菜单里逐个完成。
struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var updateController: AppUpdateController
    let toggleWindow: () -> Void

    var body: some View {
        // 状态摘要(纯展示)
        Text(viewModel.menuSummary)

        Divider()

        // 待办操作区:逐个完成 + 批量完成
        if viewModel.snapshot.hasTodo {
            ForEach(viewModel.snapshot.todos.prefix(5)) { session in
                Button("完成「\(session.projectName)」") {
                    viewModel.completeTodo(id: session.id)
                }
            }

            if viewModel.snapshot.todos.count > 1 {
                Button("全部标记完成") {
                    if confirmCompleteAllTodos(count: viewModel.snapshot.todos.count) {
                        viewModel.completeAllTodos()
                    }
                }
            }

            Divider()
        }

        Button("立即刷新") {
            viewModel.refreshNow()
        }

        Button(viewModel.panelVisibilityMenuTitle) {
            toggleWindow()
        }

        Divider()

        // 置顶模式(系统原生子菜单样式)
        Picker("置顶模式", selection: Binding(
            get: { viewModel.pinMode },
            set: { viewModel.setPinMode($0) }
        )) {
            ForEach(PinMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }

        Picker("全屏覆盖", selection: Binding(
            get: { viewModel.fullscreenOverlayMode },
            set: { viewModel.setFullscreenOverlayMode($0) }
        )) {
            ForEach(FullscreenOverlayMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }

        Divider()

        Button("检查更新…") {
            updateController.checkForUpdates()
        }
        .disabled(!updateController.canCheckForUpdates)

        SettingsMenuButton()

        Button("退出 Agent Inbox") {
            NSApp.terminate(nil)
        }
    }
}
