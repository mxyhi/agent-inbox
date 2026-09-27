import Foundation
import Testing
@testable import AgentInboxCore

private final class CLI {
    var calls: [[String]] = []
    var selectedID: String?
    var reads = 0
    var reorder = false
    var fail = false
    var ignoreSelection = false
    var paneID = 0
    var states = #"{"ok":true,"selector":"view:2/tab:1","ui":"terminal","provider_key":"codex","session_id":"wanted"},{"ok":true,"selector":"view:2/tab:2","ui":"chat","provider_key":"codex","session_id":"conv:codex:wanted","conversation_id":"conv:codex:wanted"}"#

    func run(_ args: [String]) throws -> Data {
        calls.append(args)
        let text: String
        switch Array(args.prefix(2)) {
        case ["workspace", "list"]:
            reads += 1
            text = """
            {"response":{"active_workspace_id":"workspace","workspaces":[{"id":"workspace","sections":[{"projects":[{"items":[{
              "id":"item","path":"/tmp/project","selected":\(selectedID != nil),"sessions":[
                {"id":"v7.p0.t0","split_view_id":7,"pane_id":\(paneID),"tab_index":0,"stable_id":\(reorder && reads > 1 ? 999 : 101),"is_active":\(selectedID == "v7.p0.t0")},
                {"id":"v7.p0.t1","split_view_id":7,"pane_id":0,"tab_index":1,"stable_id":102,"is_active":\(selectedID == "v7.p0.t1")}
              ]
            }]}]}]}]}}
            """
        case ["layout", "views"]:
            text = #"{"response":{"views":[{"index":2,"view_id":7}]}}"#
        case ["layout", "state"]:
            text = "{\"response\":{\"targets\":[\(states)]}}"
        case ["worktree", "select"]:
            if fail { throw OpenSessionError.commandFailed(command: "sc worktree select", exitCode: 3, stderr: "not_found") }
            if !ignoreSelection, let i = args.firstIndex(of: "--session") { selectedID = args[i + 1] }
            text = "{}"
        default:
            Issue.record("Unexpected command: \(args)")
            throw CocoaError(.featureUnsupported)
        }
        return Data(text.utf8)
    }
}
private func session() -> SessionSummary {
    SessionSummary(sessionID: "wanted", filePath: "/tmp/rollout.jsonl", cwd: "/tmp/project",
                   startedAt: nil, modifiedAt: Date(), taskCompletedAt: nil, lastAgentMessage: nil)
}

@Test func scPrefersOriginalTerminalToChatCopy() throws {
    let cli = CLI()
    try SuperconductorSessionSelector(run: cli.run).select(session: session())
    #expect(cli.calls.contains(["worktree", "select", "item", "--workspace", "workspace", "--session", "v7.p0.t0", "--json"]))
    #expect(cli.calls.contains(["layout", "state", "--worktree", "/tmp/project", "--output", "json", "--to", "view:2/tab:1", "--to", "view:2/tab:2"]))
    #expect(cli.reads == 3)
}

@Test func scSupportsExistingNativeChat() throws {
    let cli = CLI()
    cli.states = #"{"ok":true,"selector":"view:2/tab:2","ui":"chat","provider_key":"codex","conversation_id":"conv:codex:wanted"}"#
    try SuperconductorSessionSelector(run: cli.run).select(session: session())
    #expect(cli.selectedID == "v7.p0.t1")
}

@Test(arguments: [
    #"{"ok":false,"selector":"view:2/tab:1"}"#,
    #"{"ok":true,"selector":"view:2/tab:1","ui":"terminal","provider_key":"grok","session_id":"wanted"}"#,
    #"{"ok":true,"selector":"view:2/tab:1","ui":"terminal","provider_key":"codex","session_id":"other"}"#,
    #"{"ok":true,"selector":"view:2/tab:1","ui":"terminal","provider_key":"codex","session_id":"wanted"},{"ok":true,"selector":"view:2/tab:2","ui":"terminal","provider_key":"codex","session_id":"wanted"}"#
]) func scRejectsMissingWrongProviderAndAmbiguousMatches(states: String) {
    let cli = CLI(); cli.states = states
    #expect(throws: SuperconductorSessionSelector.SelectionError.self) {
        try SuperconductorSessionSelector(run: cli.run).select(session: session())
    }
    #expect(!cli.calls.contains(where: { $0.first == "worktree" }))
}

@Test func scRejectsReorderedTabs() {
    let cli = CLI(); cli.reorder = true
    #expect(throws: SuperconductorSessionSelector.SelectionError.self) {
        try SuperconductorSessionSelector(run: cli.run).select(session: session())
    }
    #expect(!cli.calls.contains(where: { $0.first == "worktree" }))
}

@Test func scReportsSelectionCommandFailure() {
    let cli = CLI(); cli.fail = true
    #expect(throws: OpenSessionError.self) {
        try SuperconductorSessionSelector(run: cli.run).select(session: session())
    }
}

@Test func scRequiresSelectionReadback() {
    let cli = CLI(); cli.ignoreSelection = true
    #expect(throws: SuperconductorSessionSelector.SelectionError.self) {
        try SuperconductorSessionSelector(run: cli.run).select(session: session())
    }
}

@Test func scDoesNotReplaceSplitTerminalWithChatCopy() {
    let cli = CLI(); cli.paneID = 5
    #expect(throws: SuperconductorSessionSelector.SelectionError.self) {
        try SuperconductorSessionSelector(run: cli.run).select(session: session())
    }
    #expect(!cli.calls.contains(where: { $0.first == "worktree" }))
}
