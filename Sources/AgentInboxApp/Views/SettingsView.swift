import AgentInboxCore
import AppKit
import SwiftUI

/// The Settings window (⌘, · the menu-bar menu): a standard macOS `Settings` scene with grouped-form
/// tabs. Everything here is a thin view over `AppModel` — the launch item, Sparkle, `FolderSync`, the MCP
/// service and `InboxModel` (Agent Inbox tab) own the actual behaviour.
struct SettingsView: View {
    /// Remembered, so Settings reopens on the tab it was left on.
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.inbox

    var body: some View {
        TabView(selection: $tab) {
            InboxSettings().tabItem { Label("Agent Inbox", systemImage: "tray") }.tag(SettingsTab.inbox)
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            SyncSettings().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.sync)
            AgentsSettings().tabItem { Label("AI Agents", systemImage: "sparkles") }.tag(SettingsTab.agents)
        }
        .frame(width: 560)
    }
}

/// A small "Experimental" capsule for features still finding their feet (sync, for now).
struct ExperimentalTag: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .help("Sync is new and still experimental")
    }
}

enum SettingsTab: String {
    case inbox, general, sync, agents
    static let storageKey = "settingsTab"
}

/// "today at 17:42", "yesterday at 09:10", "3 Nov at 17:42".
private func settingsWhen(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return String(localized: "today at \(time)") }
    if calendar.isDateInYesterday(date) { return String(localized: "yesterday at \(time)") }
    let day = date.formatted(.dateTime.day().month(.abbreviated))
    return String(localized: "\(day) at \(time)")
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var model = AppModel.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Launch at Login")
                    Text("Open Agent Inbox and its notes when you log in.")
                }
            }
            Section("Docked tabs") {
                Picker("On hover, tabs show", selection: Binding(get: { model.dockTabStyle }, set: { model.setDockTabStyle($0) })) {
                    ForEach(DockTabStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: Binding(get: { model.tabsOverFullScreen }, set: { model.setTabsOverFullScreen($0) })) {
                    Text("Show tabs over full-screen apps")
                    Text("Docked tabs also appear on every desktop and over apps in full screen.")
                }
            }
            Section("Privacy") {
                Toggle(isOn: Binding(get: { model.everyListPrivate }, set: { model.setEveryListPrivate($0) })) {
                    Text("Treat every list as private")
                    Text("Keep every list out of screen shares where macOS allows, and cover it with Cover Private Lists.")
                }
            }
            Section("About") {
                LabeledContent("Version", value: AppVersion.displayValue(
                    shortVersionString: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ))
                LabeledContent {
                    Button("Check for Updates…") { model.updater.checkForUpdates() }
                        .disabled(!model.updater.canCheckForUpdates)
                } label: {
                    Text(model.updater.canCheckForUpdates ? "Updates are checked automatically with Sparkle" : "Updates need the packaged app")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

// MARK: - Sync

private struct SyncSettings: View {
    @State private var model = AppModel.shared
    private var sync: FolderSync { model.sync }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })) {
                    HStack(spacing: 6) {
                        Text("Sync lists between Macs")
                        ExperimentalTag()
                    }
                    Text("Only the lists you choose. Which lists are open, and where they sit, stay on each Mac.")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Sync is new and still experimental. If a list looks wrong, turn sync off for it and tell us what happened.",
                          systemImage: "flask")
                    Link("Report a Problem…", destination: URL(string: "https://github.com/mxyhi/agent-inbox/issues/new")!)
                }
                .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Label {
                        Text(sync.folderDisplayName ?? String(localized: "No folder chosen"))
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                    }
                    Spacer()
                    Button("Choose…") { sync.chooseFolder() }
                }
                .disabled(!sync.isEnabled)
                if sync.isEnabled, let problem = sync.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Sync folder")
            } footer: {
                Text("Choose the same folder on each Mac. iCloud Drive, Dropbox, Google Drive, OneDrive and Syncthing folders all work.")
                    .foregroundStyle(.secondary)
            }
            if sync.isEnabled {
                Section {
                    LabeledContent {
                        Text(thisMacStatus)
                    } label: {
                        HStack(spacing: 6) {
                            Text(sync.deviceName)
                            Text("This Mac")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        }
                    }
                    if sync.peers.isEmpty {
                        Text("No other Macs yet").foregroundStyle(.secondary)
                    }
                    ForEach(sync.peers) { peer in
                        LabeledContent(peer.name, value: peer.latestChange
                            .map { String(localized: "Latest changes \(settingsWhen($0))") } ?? String(localized: "No changes yet"))
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text(sync.peers.isEmpty
                         ? "Turn on sync on your other Mac and choose this same folder."
                         : "Lists created on another Mac arrive closed. Open them from Recent Lists or Search Lists.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(model.notes) { note in
                    Toggle(isOn: Binding(
                        get: { note.isSynced && sync.isEnabled }, set: { model.setSynced(note, $0) }
                    )) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(note.color.fill).frame(width: 10, height: 10)
                            Text(note.title.isEmpty ? String(localized: "Untitled List") : note.title).lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("Lists")
            } footer: {
                let synced = model.notes.filter(\.isSynced).count
                Text(sync.isEnabled
                     ? "\(synced) of \(model.notes.count) lists sync. New lists don't sync until you turn it on, here or from the list's ⋯ menu."
                     : "Turn on sync to choose lists.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!sync.isEnabled)
        }
        .formStyle(.grouped)
        .frame(height: 540)
    }

    private var thisMacStatus: String {
        if sync.problem != nil { return String(localized: "Needs attention") }
        return sync.lastSynced == nil ? String(localized: "Starting…") : String(localized: "Up to date")
    }
}

// MARK: - AI Agents (MCP)

/// The MCP switch with live status, then one client's copy-paste (or one-click) setup. Every
/// snippet spawns the same `Tic --mcp`, so this is one command presented per client.
private struct AgentsSettings: View {
    @State private var model = AppModel.shared
    @State private var selection: String
    @State private var copied = false

    private let clients: [MCPClient]
    private let inApplications: Bool

    init() {
        let exe = Bundle.main.executableURL?.path ?? "agent-inbox"
        clients = MCPClients.all(executablePath: exe)
        inApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications")
        _selection = State(initialValue: "Claude Code")
    }

    private var client: MCPClient { clients.first { $0.id == selection } ?? clients[0] }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.mcpEnabled }, set: { model.setMCPEnabled($0) })) {
                    Text("Allow AI agents to use your lists")
                    Text("Lets Claude, Cursor and other MCP clients draft and tick your lists.")
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.mcpEnabled ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
            }
            Section {
                Picker("Client", selection: $selection) {
                    ForEach(clients, id: \.id) { Text($0.name).tag($0.id) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(client.detail).foregroundStyle(.secondary)
                    ScrollView {
                        Text(client.snippet)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 130)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    HStack(spacing: 8) {
                        if let link = client.deeplink {
                            Button("Add to \(client.name)") { open(link) }.buttonStyle(.borderedProminent)
                        }
                        Button(copied ? "Copied" : "Copy") { copy() }
                        if let path = client.configPath {
                            Button("Open Config File") { openConfig(path) }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Connect a client")
            } footer: {
                if !inApplications {
                    Text("Agent Inbox isn't in /Applications. The path in this command changes if you move the app.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onChange(of: selection) { copied = false }
    }

    private var statusText: String {
        guard model.mcpEnabled else { return String(localized: "Off") }
        let n = model.mcpConnections
        return n == 0 ? String(localized: "Running · no agents connected") : String(localized: "Running · \(n) connected")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(client.snippet, forType: .string)
        copied = true
    }

    /// Opens a client install deeplink (Cursor / VS Code).
    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    /// Opens the client's config file, or reveals its folder in Finder if the file doesn't exist yet.
    private func openConfig(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
