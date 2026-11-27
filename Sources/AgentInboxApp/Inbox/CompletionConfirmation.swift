import AppKit
import OSLog

private let completionConfirmationLogger = Logger(subsystem: "AgentInbox", category: "CompletionConfirmation")

/// 原生批量完成确认门;只有确认返回 true,调用方才写入 SQLite 状态。
@MainActor
func confirmCompleteAllTodos(count: Int) -> Bool {
    guard count > 0 else { return false }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "全部标记完成?"
    alert.informativeText = "将把 \(count) 个待办标记为完成。此操作会写入本机状态。"
    alert.addButton(withTitle: "全部完成")
    alert.addButton(withTitle: "取消")

    NSApp.activate(ignoringOtherApps: true)
    let confirmed = alert.runModal() == .alertFirstButtonReturn
    completionConfirmationLogger.info("批量完成确认结果: confirmed=\(confirmed, privacy: .public), count=\(count)")
    return confirmed
}
