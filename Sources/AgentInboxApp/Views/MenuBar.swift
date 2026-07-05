import AppKit
import AgentInboxCore
import SwiftUI

// MARK: - 菜单栏内容

/// 菜单栏下拉菜单 —— 保持系统原生交互
/// V4:摘要行显示「N 个待办 · M 个运行中」,待办可直接在菜单里逐个完成。
struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
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

        Divider()

        SettingsMenuButton()

        Button("退出 Agent Inbox") {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 设置窗口

/// 设置窗口 —— 系统原生 Form 样式
struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            // 浮窗行为
            Section {
                Picker("置顶模式", selection: Binding(
                    get: { viewModel.pinMode },
                    set: { viewModel.setPinMode($0) }
                )) {
                    ForEach(PinMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                LabeledContent("浮窗位置") {
                    Button("重置到右上角") {
                        // 拖丢了找回来:FloatingPanelController 监听此通知归位并清空持久化
                        NotificationCenter.default.post(name: .resetPanelPosition, object: nil)
                    }
                }
            } header: {
                Text("浮窗")
            } footer: {
                Text("浮窗可整体拖动,位置会自动记住")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // 数据来源
            Section {
                LabeledContent("Codex 会话目录") {
                    Text("~/.codex/sessions")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("状态存储") {
                    Text("~/Library/Application Support/Agent Inbox")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("数据")
            }

            // 版本
            Section {
                LabeledContent("版本") {
                    Text("4.0")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
    }
}
