import AppKit
import OSLog

private let completionConfirmationLogger = Logger(subsystem: "AgentInbox", category: "CompletionConfirmation")

/// 原生批量完成确认门;只有确认返回 true,调用方才写入 SQLite 状态。
@MainActor
func confirmCompleteAllTodos(count: Int) -> Bool {
    guard count > 0 else { return false }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "Mark all done?")
    alert.informativeText = String(localized: "This marks \(count) todos as done. The change is saved on this Mac.")
    alert.addButton(withTitle: String(localized: "Mark All Done"))
    alert.addButton(withTitle: String(localized: "Cancel"))

    NSApp.activate(ignoringOtherApps: true)
    let confirmed = alert.runModal() == .alertFirstButtonReturn
    completionConfirmationLogger.info("批量完成确认结果: confirmed=\(confirmed, privacy: .public), count=\(count)")
    return confirmed
}
