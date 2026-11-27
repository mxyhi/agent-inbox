import AgentInboxCore
import AppKit
import SwiftUI

/// 收件箱便签里的 Agent 会话行，插在 tic 任务列表的最上面（同一个滚动区），下面仍是用户自己的任务。
/// 行样式照搬 tic 的任务行（`TaskRowView`）：待办点圆圈标记已处理、点文字打开会话；运行中的会话用转动的虚线圈。
/// 这些行来自会话快照，不是 task 行：不能编辑、拖动或嵌套。
struct InboxSessionRows: View {
    let inbox: InboxModel
    let theme: NoteTheme
    /// 下面还有用户任务时画一条分隔线。
    let hasTasksBelow: Bool

    private var snapshot: AgentSnapshot { inbox.snapshot }

    var body: some View {
        if !snapshot.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snapshot.todos) { session in
                    InboxTodoRow(
                        session: session,
                        theme: theme,
                        onComplete: { inbox.completeTodo(id: session.id) },
                        onOpen: { inbox.openSession(id: session.id) },
                        onCreateFilter: { inbox.addPromptFilterRule(from: session.id) }
                    )
                }
                if !snapshot.running.isEmpty {
                    Text("Running")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.secondary)
                        .padding(.top, snapshot.todos.isEmpty ? 2 : 8)
                        .padding(.bottom, 2)
                    ForEach(snapshot.running) { session in
                        InboxRunningRow(session: session, theme: theme, onOpen: { inbox.openSession(id: session.id) })
                    }
                }
                if hasTasksBelow {
                    Rectangle()
                        .fill(theme.secondary.opacity(0.25))
                        .frame(height: 0.5)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, NoteLayout.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu { contextMenuItems }
            .animation(.easeInOut(duration: 0.2), value: snapshot)
            .onChange(of: snapshot.todos.count) { oldCount, newCount in
                if newCount > oldCount { announce(String(localized: "New agent todo")) }
            }
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if !snapshot.todos.isEmpty {
            Button("Mark All Done") {
                if confirmCompleteAllTodos(count: snapshot.todos.count) {
                    inbox.completeAllTodos()
                }
            }
            Divider()
        }
        Button("Refresh Now") { inbox.refreshNow() }
    }

    /// 出现新待办时向 VoiceOver 播报。
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

// MARK: - 待办行

/// 一条待办，长得像 tic 的任务行。等你回复的待办圆圈用便签主题的强调色，正文先写「等你回复」。
private struct InboxTodoRow: View {
    let session: SessionSummary
    let theme: NoteTheme
    let onComplete: () -> Void
    let onOpen: () -> Void
    let onCreateFilter: () -> Void

    /// 点圆圈后先画出勾，稍等再从快照移除，和 tic 勾选任务的手感一致。
    @State private var checked = false

    private var needsReply: Bool { session.lifecycleState == .waitingForUser }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: check) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(checked ? theme.checkbox : (needsReply ? theme.accent : theme.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(needsReply ? "Mark as handled (doesn't answer the session for you)" : "Mark as handled")

            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .foregroundStyle(theme.task)
                    .strikethrough(checked, color: theme.completed.opacity(0.7))
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .help("Open session")

            InboxMeta(provider: session.provider, theme: theme) {
                RelativeAge(date: needsReply ? session.modifiedAt : session.taskCompletedAt ?? session.modifiedAt)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Open Session", action: onOpen)
            Button("Mark as Handled", action: check)
            if session.firstPrompt?.trimmedNonEmpty != nil {
                Button("Filter Out This Prompt", action: onCreateFilter)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Todo: \(session.projectName)")
    }

    private var detail: String? {
        if needsReply {
            let question = session.pendingQuestion?.trimmedNonEmpty ?? String(localized: "Needs your choice, approval or input")
            return String(localized: "Waiting for your reply: \(question)")
        }
        return session.lastAgentMessage?.trimmedNonEmpty ?? session.firstPrompt?.trimmedNonEmpty
    }

    private func check() {
        guard !checked else { return }
        withAnimation(.easeInOut(duration: 0.15)) { checked = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            onComplete()
        }
    }
}

// MARK: - 运行中行

/// 一条运行中的会话：没有可勾的圆圈，只用转动的虚线圈表示还在干活；右侧是已运行时长。
private struct InboxRunningRow: View {
    let session: SessionSummary
    let theme: NoteTheme
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(theme.secondary)
                .symbolEffect(.pulse, options: .repeating)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .foregroundStyle(theme.task)
                if let prompt = session.firstPrompt?.trimmedNonEmpty {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InboxMeta(provider: session.provider, theme: theme) {
                if let startedAt = session.startedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu { Button("Open Session", action: onOpen) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Running: \(session.projectName)")
    }
}

// MARK: - 行尾信息

/// 行尾的小字：会话源 + 时间，混排多源时用来区分。
private struct InboxMeta<Time: View>: View {
    let provider: AgentProvider
    let theme: NoteTheme
    @ViewBuilder let time: () -> Time

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            time()
            Text(provider.label)
        }
        .font(.caption)
        .foregroundStyle(theme.secondary)
        .fixedSize()
    }
}

/// 「刚刚 / N 分钟前 / N 小时前 / N 天前」（随系统语言），每分钟刷新一次。
private struct RelativeAge: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.format(date, now: context.date)).monospacedDigit()
        }
    }

    static func format(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return String(localized: "Just now") }
        if interval < 3600 { return String(localized: "\(Int(interval / 60))m ago") }
        if interval < 86400 { return String(localized: "\(Int(interval / 3600))h ago") }
        if interval < 604800 { return String(localized: "\(Int(interval / 86400))d ago") }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

private extension String {
    /// 去掉首尾空白；空串返回 nil。
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
