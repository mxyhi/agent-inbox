import Foundation

/// 用公开 CLI 查询原生会话身份，再选择已有侧栏行；不调用可能导入新聊天的 chat select。
struct SuperconductorSessionSelector {
    let run: ([String]) throws -> Data

    func select(session: SessionSummary) throws {
        guard let cwd = session.cwd, !cwd.isEmpty else { throw OpenSessionError.missingWorkingDirectory }
        let before = try workspace(for: cwd)
        let views: Envelope<Views> = try query(["layout", "views", "--worktree", cwd, "--output", "json"])
        var candidates: [(Row, String)] = []
        for row in before.item.sessions {
            guard let view = views.response.views.first(where: { $0.view_id == row.split_view_id }) else { continue }
            // 内部 pane_id 不等于 CLI 的 pane 序号；没有可靠映射时不能猜分屏位置。
            guard row.pane_id == 0,
                  before.item.sessions.filter({ $0.split_view_id == row.split_view_id && $0.tab_index == row.tab_index }).count == 1 else { continue }
            candidates.append((row, "view:\(view.index)/tab:\(row.tab_index + 1)"))
        }
        guard !candidates.isEmpty else { throw SelectionError.notFound }
        let states: Envelope<States> = try query(
            ["layout", "state", "--worktree", cwd, "--output", "json"] + candidates.flatMap { ["--to", $0.1] }
        )
        let native = matches(session: session, candidates: candidates, states: states.response.targets, nativeOnly: true)
        // 没有检查全部 pane 时，不用聊天副本替代可能藏在分屏中的原终端。
        if native.isEmpty && candidates.count != before.item.sessions.count { throw SelectionError.notFound }
        let found = native.isEmpty
            ? matches(session: session, candidates: candidates, states: states.response.targets, nativeOnly: false)
            : native
        guard !found.isEmpty else { throw SelectionError.notFound }
        guard found.count == 1, let target = found.first else { throw SelectionError.ambiguous }

        // 选择地址含索引；拒绝查询期间发生重排的标签，避免跳到别的会话。
        let current = try workspace(for: cwd)
        guard current.workspaceID == before.workspaceID, current.item.id == before.item.id,
              current.item.sessions == before.item.sessions else { throw SelectionError.changed }
        _ = try run(["worktree", "select", current.item.id, "--workspace", current.workspaceID,
                     "--session", target.id, "--json"])
        let selected = try workspace(for: cwd)
        guard selected.workspaceID == current.workspaceID, selected.item.selected,
              selected.item.sessions.contains(where: { $0.id == target.id && $0.stable_id == target.stable_id && $0.is_active }) else {
            throw SelectionError.changed
        }
    }

    private func matches(session: SessionSummary, candidates: [(Row, String)], states: [State], nativeOnly: Bool) -> [Row] {
        candidates.compactMap { row, selector in
            guard let state = states.first(where: { $0.selector == selector }), state.ok,
                  state.provider_key == session.provider.rawValue else { return nil }
            if nativeOnly { return state.session_id == session.sessionID ? row : nil }
            let conversationID = "conv:\(session.provider.rawValue):\(session.sessionID)"
            return state.ui == "chat" && state.conversation_id == conversationID ? row : nil
        }
    }

    private func workspace(for cwd: String) throws -> (workspaceID: String, item: Item) {
        let envelope: Envelope<Workspaces> = try query(["workspace", "list", "--json"])
        let path = URL(filePath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        let found = envelope.response.workspaces.flatMap { workspace in
            workspace.sections.flatMap(\.projects).flatMap(\.items).compactMap { item -> (String, Item)? in
                guard URL(filePath: item.path).resolvingSymlinksInPath().standardizedFileURL.path == path else { return nil }
                return (workspace.id, item)
            }
        }
        let active = found.filter { $0.0 == envelope.response.active_workspace_id }
        let scoped = active.isEmpty ? found : active
        guard scoped.count == 1, let result = scoped.first else {
            throw scoped.isEmpty ? SelectionError.notFound : SelectionError.ambiguous
        }
        return result
    }

    private func query<T: Decodable>(_ arguments: [String]) throws -> T {
        try JSONDecoder().decode(T.self, from: run(arguments))
    }

    private struct Envelope<T: Decodable>: Decodable { let response: T }
    private struct Workspaces: Decodable {
        let active_workspace_id: String?
        let workspaces: [Workspace]
    }
    private struct Workspace: Decodable { let id: String; let sections: [Section] }
    private struct Section: Decodable { let projects: [Project] }
    private struct Project: Decodable { let items: [Item] }
    private struct Item: Decodable { let id: String; let path: String; let selected: Bool; let sessions: [Row] }
    private struct Row: Decodable, Equatable {
        let id: String
        let split_view_id: Int
        let pane_id: Int
        let tab_index: Int
        let stable_id: UInt64?
        let is_active: Bool
    }
    private struct Views: Decodable { let views: [View] }
    private struct View: Decodable { let index: Int; let view_id: Int }
    private struct States: Decodable { let targets: [State] }
    private struct State: Decodable {
        let ok: Bool
        let selector: String
        let provider_key: String?
        let session_id: String?
        let conversation_id: String?
        let ui: String?
    }

    enum SelectionError: LocalizedError {
        case notFound, ambiguous, changed
        var errorDescription: String? {
            switch self {
            case .notFound: "未找到可精确定位的 SC 会话标签页，或会话位于暂不支持的分屏中"
            case .ambiguous: "多个 SC 标签页匹配同一会话"
            case .changed: "SC 标签页状态已变化或选择结果未通过回读"
            }
        }
    }
}
