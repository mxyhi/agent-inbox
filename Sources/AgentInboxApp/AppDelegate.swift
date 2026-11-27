import AppKit

/// App lifecycle owner. As a plain SwiftPM executable (no .app bundle yet) we must explicitly
/// adopt a regular activation policy so the app gets a Dock icon and can take foreground focus.
/// All real state lives in `AppModel.shared`; this just sequences launch and the Dock menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var newNoteKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { await AppModel.shared.bootstrap() }
        installNewNoteShortcut()
        // 系统通知代理由 UserNotificationController 安装（点击通知打开对应会话）。
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    /// ⌘N → New Note while the app is active. A menu-style `MenuBarExtra` button's
    /// `keyboardShortcut` only fires while that menu is open, so we dispatch it ourselves via a
    /// local key monitor (fires whenever any of the app's windows is key).
    private func installNewNoteShortcut() {
        newNoteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Membership test (not == .command) so Caps Lock / Fn in the flags don't break it,
            // and case-insensitive so "N" under Caps Lock still matches.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command),
                  !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control),
                  event.charactersIgnoringModifiers?.lowercased() == "n" else { return event }
            Task { @MainActor in AppModel.shared.newNote() }
            return nil   // consume
        }
    }

    /// Click the Dock icon with no notes on screen → open the Agent inbox note, so the app never
    /// looks dead after every note was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if AppModel.shared.windows.openCount == 0 { AppModel.shared.openInbox() }
        return true
    }

    /// Right-click the Dock icon → New List.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New List", action: #selector(newListFromDock), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newListFromDock() {
        AppModel.shared.newNote()
    }
}
