import MTodoCore
import SwiftUI

// MARK: - 待办行

/// 待办行 —— 涟漪橙点 + 项目名 + 相对时间 + 完成按钮
/// 首个待办额外显示 Codex 最后一条消息摘要(≤2 行),后续待办保持单行紧凑。
struct TodoRow: View {
    let session: CodexSessionSummary
    /// 是否显示消息摘要(仅列表首个待办为 true,保持单一焦点)
    let showMessage: Bool
    let onComplete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.Metrics.rowSpacing) {
                StatusOrb(kind: .todo)

                Text(session.projectName)
                    .font(DS.Fonts.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                RelativeTimeText(date: session.taskCompletedAt ?? session.modifiedAt)

                CompleteButton(action: onComplete)
            }

            // 消息摘要:Codex 干完了什么,等待确认的核心内容
            if showMessage, let message = trimmedMessage {
                Text(message)
                    .font(DS.Fonts.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    // 与项目名左对齐(光点框 14 + 间距 8 = 22)
                    .padding(.leading, DS.Metrics.orbFrame + DS.Metrics.rowSpacing)
            }
        }
        .padding(.vertical, DS.Metrics.rowPaddingV)
        .padding(.horizontal, DS.Metrics.rowPaddingH)
        .background(
            RoundedRectangle(cornerRadius: DS.Metrics.rowRadius, style: .continuous)
                .fill(isHovered ? DS.Colors.rowHover : .clear)
        )
        .animation(DS.Anim.hover, value: isHovered)
        .onHover { isHovered = $0 }
        // 无障碍:整行合并为一个元素,动作即「标记完成」
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("待办:\(session.projectName)")
        .accessibilityValue(trimmedMessage ?? "")
        .accessibilityAction(named: "标记完成", onComplete)
    }

    /// 去除首尾空白后的消息(空则不渲染)
    private var trimmedMessage: String? {
        guard let message = session.lastAgentMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        else { return nil }
        return message
    }
}

// MARK: - 运行行

/// 运行行 —— 呼吸蓝点 + 项目名 + 实时跳动的运行时长
/// 无操作,纯感知;所以不做 hover 高亮,保持安静。
struct RunningRow: View {
    let session: CodexSessionSummary

    var body: some View {
        HStack(spacing: DS.Metrics.rowSpacing) {
            StatusOrb(kind: .running)

            Text(session.projectName)
                .font(DS.Fonts.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            // 运行时长:session_meta 启动时间;缺失时退化为文件 mtime
            ElapsedTimeText(since: session.startedAt ?? session.modifiedAt)
        }
        .padding(.vertical, DS.Metrics.rowPaddingV)
        .padding(.horizontal, DS.Metrics.rowPaddingH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("运行中:\(session.projectName)")
    }
}

// MARK: - 完成按钮

/// 圆形完成按钮 —— 默认低调灰底,hover 填充绿色
/// 这是面板上唯一的按钮(V4 去 chrome:刷新/设置全部收进右键菜单)。
struct CompleteButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovered ? Color.white : Color.secondary)
                .frame(width: DS.Metrics.completeButtonSize, height: DS.Metrics.completeButtonSize)
                .background(
                    Circle().fill(isHovered ? DS.Colors.done : DS.Colors.buttonIdle)
                )
        }
        .buttonStyle(.plain)
        .animation(DS.Anim.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .help("标记完成")
        .accessibilityLabel("标记完成")
    }
}

// MARK: - 折叠提示

/// 超出展示上限时的弱化提示行,如「还有 2 个待办」
struct OverflowLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Fonts.overflow)
            .foregroundStyle(.tertiary)
            .padding(.leading, DS.Metrics.rowPaddingH + DS.Metrics.orbFrame + DS.Metrics.rowSpacing)
            .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview("会话行") {
    VStack(alignment: .leading, spacing: 2) {
        TodoRow(session: .mockTodo, showMessage: true, onComplete: {})
        TodoRow(session: .mockTodo2, showMessage: false, onComplete: {})
        OverflowLabel(text: "还有 2 个待办")
        Divider()
        RunningRow(session: .mockRunning)
    }
    .padding(8)
    .frame(width: 300)
}

// MARK: - Mock

extension CodexSessionSummary {
    static var mockTodo: CodexSessionSummary {
        CodexSessionSummary(
            id: "todo-1",
            filePath: "/tmp/rollout-a.jsonl",
            cwd: "/Users/dev/workspace/m-todo",
            startedAt: Date().addingTimeInterval(-1800),
            modifiedAt: Date().addingTimeInterval(-180),
            taskCompletedAt: Date().addingTimeInterval(-180),
            lastAgentMessage: "审计完了,基于本机 codex-cli 0.142.5。已执行 features disable external_migration,当前核心功能均已开启。"
        )
    }

    static var mockTodo2: CodexSessionSummary {
        CodexSessionSummary(
            id: "todo-2",
            filePath: "/tmp/rollout-b.jsonl",
            cwd: "/Users/dev/workspace/_all_do",
            startedAt: Date().addingTimeInterval(-7200),
            modifiedAt: Date().addingTimeInterval(-3600),
            taskCompletedAt: Date().addingTimeInterval(-3600),
            lastAgentMessage: "完成了依赖升级。"
        )
    }

    static var mockRunning: CodexSessionSummary {
        CodexSessionSummary(
            id: "run-1",
            filePath: "/tmp/rollout-c.jsonl",
            cwd: "/Users/dev/workspace/side-project",
            startedAt: Date().addingTimeInterval(-154),
            modifiedAt: Date(),
            taskCompletedAt: nil,
            lastAgentMessage: nil
        )
    }
}
