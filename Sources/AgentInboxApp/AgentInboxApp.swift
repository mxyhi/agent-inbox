import AgentInboxCore
import AppKit
import SwiftUI

struct AgentInboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Native .menu style (default): its content is rebuilt each time the menu opens, so it
        // reliably reflects the current lists and todos — unlike .window, which didn't re-render here.
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }

        Settings {
            SettingsView()
        }
    }
}

/// 菜单栏图标跟随 Agent 状态：待办 > 运行中 > 完成历史 > 空闲。
/// label 必须直接读 `InboxModel`，MenuBarExtra 才会随快照重绘。
private struct MenuBarLabel: View {
    private var inbox: InboxModel { AppModel.shared.inbox }

    var body: some View {
        Label("Agent Inbox", systemImage: inbox.menuBarSystemImage)
    }
}

/// 菜单栏菜单：先是 Agent 待办（逐个处理或批量完成），再是 tic 的清单入口，最后是设置、更新与退出。
private struct MenuBarContent: View {
    private var model: AppModel { AppModel.shared }
    private var inbox: InboxModel { model.inbox }
    private static let recentCount = 5
    private static let moreCount = 95   // 5 + 95 = up to 100 reachable from the menu
    private static let todoCount = 5

    var body: some View {
        Text(inbox.menuSummary)

        if inbox.snapshot.hasTodo {
            ForEach(inbox.snapshot.todos.prefix(Self.todoCount)) { session in
                if session.lifecycleState == .waitingForUser {
                    Button("去处理「\(session.projectName)」") { inbox.openSession(id: session.id) }
                }
                Button("完成「\(session.projectName)」") { inbox.completeTodo(id: session.id) }
            }
            if inbox.snapshot.todos.count > 1 {
                Button("全部标记完成") {
                    if confirmCompleteAllTodos(count: inbox.snapshot.todos.count) {
                        inbox.completeAllTodos()
                    }
                }
            }
        }

        Button("显示 Agent 收件箱") { model.openInbox() }
        Button("立即刷新") { inbox.refreshNow() }

        Divider()

        Button("New List") { model.newNote() }
            .keyboardShortcut("n")   // hint + works while the menu is open; AppDelegate covers the rest

        let recent = model.notes.sorted { $0.updatedAt > $1.updatedAt }
        if !recent.isEmpty {
            Section("Recent Lists") {
                ForEach(Array(recent.prefix(Self.recentCount))) { note in
                    Button(label(note)) { model.open(note) }
                }
            }
            let more = Array(recent.dropFirst(Self.recentCount).prefix(Self.moreCount))
            if !more.isEmpty {
                Menu("More Lists") {
                    ForEach(more) { note in
                        Button(label(note)) { model.open(note) }
                    }
                }
            }
        }

        Button("Search Lists…") { model.openSearch() }

        // For a share where macOS still captures private lists (ScreenCaptureKit, macOS 15.4+).
        Toggle("Cover Private Lists", isOn: Binding(
            get: { model.coveringPrivate }, set: { model.setCoveringPrivate($0) }
        ))

        Divider()

        Button("检查更新…") { model.updater.checkForUpdates() }
            .disabled(!model.updater.canCheckForUpdates)

        SettingsMenuItem()

        Button("退出 Agent Inbox") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(_ note: Note) -> String {
        note.title.isEmpty ? "Untitled List" : note.title
    }
}

/// Opens Settings and brings it forward: opening a window from a menu-bar menu doesn't make the app
/// active, so without `activate` it would appear behind whatever app was in front.
private struct SettingsMenuItem: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
    }
}
