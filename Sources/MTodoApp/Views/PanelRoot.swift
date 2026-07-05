import AppKit
import MTodoCore
import SwiftUI

/// 浮窗根视图 —— 内容驱动尺寸的自适应面板
/// 空态 = 微型胶囊;有会话 = 300pt 宽列表卡(待办在前、运行中在后)。
/// 面板上没有任何常驻按钮:唯一操作是待办行的完成按钮,其余全部收进右键菜单。
struct PanelRoot: View {
    @ObservedObject var viewModel: AppViewModel
    /// 右键菜单「隐藏浮窗」回调(由 FloatingPanelController 注入)
    let onHide: () -> Void

    var body: some View {
        content
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.panelRadius, style: .continuous))
            // 发丝描边:让浮窗在任何壁纸上都有清晰边缘
            .overlay(
                RoundedRectangle(cornerRadius: DS.Metrics.panelRadius, style: .continuous)
                    .strokeBorder(DS.Colors.hairline, lineWidth: 0.5)
            )
            .contextMenu { contextMenuItems }
            // fixedSize:面板取理想尺寸,配合 NSHostingView.sizingOptions 驱动窗口收放
            .fixedSize()
            .animation(DS.Anim.state, value: viewModel.snapshot)
            // 出现新待办时向 VoiceOver 播报
            .onChange(of: viewModel.snapshot.todos.count) { oldCount, newCount in
                if newCount > oldCount {
                    announce("有新的 Codex 待办")
                }
            }
    }

    // MARK: - 内容分发

    @ViewBuilder
    private var content: some View {
        if viewModel.snapshot.isEmpty {
            IdleCapsule(hasHistory: viewModel.snapshot.hasCompletedHistory)
                .transition(.opacity)
        } else {
            SessionList(snapshot: viewModel.snapshot) { id in
                viewModel.completeTodo(id: id)
            }
            .transition(.opacity)
        }
    }

    // MARK: - 右键菜单(V4 去 chrome 的去处)

    @ViewBuilder
    private var contextMenuItems: some View {
        if viewModel.snapshot.hasTodo {
            Button("全部标记完成") {
                viewModel.completeAllTodos()
            }
            Divider()
        }

        Button("立即刷新") {
            viewModel.refreshNow()
        }

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

        Button("隐藏浮窗") {
            onHide()
        }

        Divider()

        Button("退出 m-todo") {
            NSApp.terminate(nil)
        }
    }

    /// VoiceOver 播报
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

// MARK: - 空态胶囊

/// 空态微型胶囊 —— 没有任务时把存在感降到最低
/// 从未完成过任务:灰点 + "Codex";全部处理完:绿色对勾 + "Codex"。
struct IdleCapsule: View {
    let hasHistory: Bool

    var body: some View {
        HStack(spacing: 6) {
            if hasHistory {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.done)
            } else {
                StatusOrb(kind: .idle)
            }

            Text("Codex")
                .font(DS.Fonts.capsule)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasHistory ? "Codex,全部完成" : "Codex,空闲")
    }
}

// MARK: - 会话列表

/// 会话列表 —— 待办优先(需要行动),运行中次之(纯感知)
/// 各区最多展示 3 条,溢出折叠为提示行,防止面板无限长高。
struct SessionList: View {
    let snapshot: AgentSnapshot
    let onComplete: (String) -> Void

    /// 每区展示上限
    private static let sectionLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 待办区:新完成的排前,仅首个显示消息摘要
            ForEach(Array(snapshot.todos.prefix(Self.sectionLimit).enumerated()), id: \.element.id) { index, session in
                TodoRow(
                    session: session,
                    showMessage: index == 0,
                    onComplete: { onComplete(session.id) }
                )
            }

            if snapshot.todos.count > Self.sectionLimit {
                OverflowLabel(text: "还有 \(snapshot.todos.count - Self.sectionLimit) 个待办")
            }

            // 两区之间的分隔线(都非空时才需要)
            if snapshot.hasTodo && snapshot.isActive {
                Divider()
                    .padding(.horizontal, DS.Metrics.rowPaddingH)
                    .padding(.vertical, 2)
            }

            // 运行区:最近活跃的排前
            ForEach(snapshot.running.prefix(Self.sectionLimit)) { session in
                RunningRow(session: session)
            }

            if snapshot.running.count > Self.sectionLimit {
                OverflowLabel(text: "还有 \(snapshot.running.count - Self.sectionLimit) 个运行中")
            }
        }
        .padding(DS.Metrics.panelPadding)
        .frame(width: DS.Metrics.listWidth)
    }
}

// MARK: - 设置菜单项

/// 「设置…」菜单项 —— app 是 accessory(无 Dock),打开设置前必须先激活自身
struct SettingsMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}
