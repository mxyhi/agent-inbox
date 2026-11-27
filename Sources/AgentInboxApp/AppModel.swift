import AgentInboxCore
import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// App-wide coordinator. Bridges the SwiftUI menu bar scene and the AppKit window layer (which
/// otherwise can't reach each other): it owns the shared `AppDatabase` + `NoteWindowManager`,
/// streams the live list of notes for the menu bar, and exposes the high-level actions invoked
/// from the menu bar, the Dock menu, and a note's "+" button.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let database: AppDatabase
    let windows: NoteWindowManager
    /// Agent 会话快照：收件箱便签、菜单栏与设置共用。
    let inbox = InboxModel()
    /// Sparkle 更新（替代 tic 自带的 GitHub Releases 更新器）。
    let updater = AppUpdateController()
    let sync: FolderSync
    @ObservationIgnored private let mcp: MCPService

    /// All saved notes (ascending `sortIndex`, i.e. creation order) — drives the menu bar list.
    /// Stays in sync as notes are created, renamed, or deleted.
    private(set) var notes: [Note] = []

    @ObservationIgnored private var notesObservation: Task<Void, Never>?
    @ObservationIgnored private var searchWindow: NSWindow?
    /// 收件箱便签的 id（启动时确保存在）。
    @ObservationIgnored private(set) var inboxNoteID: UUID?

    private init() {
        // The DB lives in Application Support; fall back to in-memory so the app still runs if
        // that can't be opened for some reason.
        guard let db = (try? AppDatabase.makeShared()) ?? (try? AppDatabase.makeInMemory()) else {
            fatalError("Agent Inbox: unable to open a database")
        }
        self.database = db
        self.windows = NoteWindowManager(appDatabase: db)
        self.mcp = MCPService(database: db)
        let support = (try? AppDatabase.supportDirectory()) ?? FileManager.default.temporaryDirectory
        self.sync = FolderSync(database: db, stateURL: support.appendingPathComponent("sync-state.json"))
        windows.sync = sync
        windows.inbox = inbox
        NSLog("[Agent Inbox] Database ready at \(db.path)")
        mcp.onConnectionCountChange = { [weak self] count in
            Task { @MainActor in self?.mcpConnections = count }
        }
        // Window pokes the MCP tools need, hopped to the main actor (the service runs off it).
        mcp.windowActions = MCPTools.WindowActions(
            open: { [weak self] id in await self?.windows.openNoteByID(id) },
            close: { [weak self] id in await self?.windows.closeNoteByID(id) },
            setFrame: { [weak self] id, rect in await self?.windows.setFrame(id, to: rect) },
            focus: { [weak self] id in await self?.windows.focusNoteByID(id) }
        )
        // A list deleted on another Mac is already gone from the database; take its panel down.
        sync.onNotesDeleted = { [weak self] ids in
            for id in ids { Task { await self?.windows.closeNoteByID(id) } }
        }
    }

    /// Run once after launch. 顺序：持久化状态 → 确保收件箱便签 → 恢复便签窗口 → 首扫与 FSEvents。
    func bootstrap() async {
        windows.everyListPrivate = everyListPrivate
        windows.dockTabStyle = dockTabStyle
        windows.tabsOverFullScreen = tabsOverFullScreen
        await inbox.prepare()
        updater.start(proxyConfig: inbox.updateProxyConfig)
        await ensureInboxNote()
        await windows.restoreAll()
        startObservingNotes()
        applyLaunchAtLogin(launchAtLogin)   // honor the saved preference (effective when packaged)
        if mcpEnabled { applyMCPEnabled(true) }
        sync.start()
        await inbox.start()
    }

    func shutdown() {
        inbox.stop()
    }

    // MARK: - Agent 收件箱

    /// 首次启动插入收件箱便签：沿用旧浮窗的右上角锚点，没有则放在主屏右上角。
    /// 默认置顶（旧浮窗一直在前面）；之后和普通清单一样由便签上的图钉决定。
    private func ensureInboxNote() async {
        let size = CGSize(width: 320, height: 380)
        let topRight = inbox.legacyPanelAnchor.map { CGPoint(x: $0.topRightX, y: $0.topRightY) }
            ?? NSScreen.main.map { CGPoint(x: $0.visibleFrame.maxX - 16, y: $0.visibleFrame.maxY - 16) }
            ?? CGPoint(x: 1200, y: 800)
        let template = Note(
            title: "Agent Inbox", color: .graphite, material: .glass,
            frameX: topRight.x - size.width, frameY: topRight.y - size.height,
            frameW: size.width, frameH: size.height, floatOnTop: true, kind: .agentInbox
        )
        do {
            let note = try await database.ensureAgentInboxNote(template)
            inboxNoteID = note.id
            NSLog("[Agent Inbox] inbox note ready: open=\(note.isOpen)")
        } catch {
            NSLog("[Agent Inbox] inbox note unavailable: \(error)")
        }
    }

    /// 打开（或带到前面）收件箱便签：菜单栏、通知点击时使用。
    func openInbox() {
        guard let id = inboxNoteID else { return }
        Task {
            await windows.focusNoteByID(id)
            NSApp.activate()
        }
    }

    private func startObservingNotes() {
        notesObservation?.cancel()
        notesObservation = Task { [weak self, database] in
            do {
                for try await list in database.observeNotes() {
                    self?.notes = list
                }
            } catch {
                NSLog("[Agent Inbox] notes observation ended: \(error)")
            }
        }
    }

    // MARK: - Actions

    /// Create and open a fresh note (cascaded). Used by every "new list" surface.
    func newNote() {
        NSApp.activate()
        Task { await windows.newNote() }
    }

    /// Open a note (or bring it to front if already open) and activate the app.
    func open(_ note: Note) {
        windows.openNote(note)
        NSApp.activate()
    }

    /// Bring all open notes to the front.
    func showAll() {
        windows.showAll()
        NSApp.activate()
    }

    /// Whether a list syncs with the user's other Macs (Settings › Sync's list of lists).
    func setSynced(_ note: Note, _ on: Bool) {
        Task { [database] in try? await database.updateNoteSynced(id: note.id, isSynced: on) }
    }

    /// Permanently delete a note (and its tasks, via the FK cascade). Removed from the list
    /// immediately so it can't be reopened during the async delete; the observation confirms.
    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        Task { await windows.deleteNote(note) }
    }

    /// Opens the searchable "Lists" palette — a floating, centered panel that always comes to the
    /// front when called. Reuses a single instance. (A real window, so search/delete re-render
    /// reliably, unlike the menu-bar popover.)
    func openSearch() {
        if searchWindow == nil {
            searchWindow = Self.floatingPanel(width: 700, height: 440, content: ListsSearchView())
        }
        searchWindow.map(present)
    }

    /// A borderless-looking floating panel hosting `content` — the shell of the Lists palette.
    /// Created once and reused.
    private static func floatingPanel(width: CGFloat, height: CGFloat, content: some View) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    /// Brings a panel up centered on the pointer's display and on top, every time it's called.
    private func present(_ window: NSWindow) {
        centerOnActiveDisplay(window)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Dead-centre of the display the pointer is on. `NSWindow.center()` isn't that: it sits above
    /// centre, and on whichever display the reused panel was last shown.
    private func centerOnActiveDisplay(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        guard let area = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame
        else { return }
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
    }

    /// Closes the Lists palette (Escape / pick a list / its close button).
    func dismissSearch() {
        searchWindow?.orderOut(nil)
    }

    // MARK: - Privacy

    private static let everyListPrivateKey = "everyListPrivate"

    /// Settings › General › Treat every list as private: every list stays out of screen shares, as if each
    /// had its own Private switch on.
    private(set) var everyListPrivate: Bool = UserDefaults.standard.bool(forKey: AppModel.everyListPrivateKey)

    func setEveryListPrivate(_ on: Bool) {
        everyListPrivate = on
        UserDefaults.standard.set(on, forKey: Self.everyListPrivateKey)
        windows.everyListPrivate = on
    }

    /// Menu bar › Cover Private Lists: private lists show a plain cover, for this session.
    private(set) var coveringPrivate = false

    func setCoveringPrivate(_ on: Bool) {
        coveringPrivate = on
        windows.coveringPrivate = on
    }

    // MARK: - Edge dock

    private static let dockTabStyleKey = "dockTabStyle"
    private static let tabsOverFullScreenKey = "dockTabsOverFullScreen"

    /// Settings › General › Docked tabs: what a docked note's tab shows once hovered out of its sliver.
    private(set) var dockTabStyle: DockTabStyle =
        DockTabStyle(rawValue: UserDefaults.standard.string(forKey: AppModel.dockTabStyleKey) ?? "") ?? .titleCount

    func setDockTabStyle(_ style: DockTabStyle) {
        dockTabStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.dockTabStyleKey)
        windows.dockTabStyle = style
    }

    /// Settings › General › Show tabs over full-screen apps (off: tabs stay on their own desktop).
    private(set) var tabsOverFullScreen: Bool = UserDefaults.standard.bool(forKey: AppModel.tabsOverFullScreenKey)

    func setTabsOverFullScreen(_ on: Bool) {
        tabsOverFullScreen = on
        UserDefaults.standard.set(on, forKey: Self.tabsOverFullScreenKey)
        windows.tabsOverFullScreen = on
    }

    // MARK: - MCP (AI agents)

    private static let mcpEnabledKey = "mcpEnabled"

    /// Whether AI agents may drive the lists over MCP. Off by default and remembered; the socket exists
    /// only while this is on, so a client spawning `agent-inbox --mcp` meanwhile fails fast with a hint.
    private(set) var mcpEnabled: Bool = UserDefaults.standard.bool(forKey: AppModel.mcpEnabledKey)

    /// Agents connected right now (the MCP window's status line).
    private(set) var mcpConnections = 0

    var mcpSocketPath: String { mcp.socketPath }

    func setMCPEnabled(_ enabled: Bool) {
        mcpEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.mcpEnabledKey)
        applyMCPEnabled(enabled)
    }

    private func applyMCPEnabled(_ enabled: Bool) {
        guard enabled else { return mcp.stop() }
        do {
            try mcp.start()
            NSLog("[Agent Inbox] MCP listening at \(mcp.socketPath)")
        } catch {
            NSLog("[Agent Inbox] MCP failed to start: \(error)")
            mcpEnabled = false
        }
    }

    // MARK: - Launch at login

    private static let launchAtLoginKey = "launchAtLogin"

    /// The user's "open at login" preference (drives the menu checkmark). Stored & @Observable so
    /// the menu updates the tick live; persisted so it survives relaunch. The actual `SMAppService`
    /// registration only takes effect for a packaged `.app` (a bare `swift run` executable can't
    /// be a login item).
    private(set) var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: AppModel.launchAtLoginKey)

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled   // @Observable → the menu checkmark updates immediately
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginKey)
        applyLaunchAtLogin(enabled)
    }

    /// Reconciles the actual login-item registration with the saved preference.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let status) where status != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break
            }
        } catch {
            NSLog("[Agent Inbox] Launch at Login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
