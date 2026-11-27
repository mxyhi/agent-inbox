import Foundation
import MCP
import Testing
@testable import AgentInboxApp

/// 收件箱便签与 tic 清单共用 note 表和窗口层，但不能出现在清单、同步和 MCP 里。
@Suite("Agent inbox note")
struct AgentInboxNoteTests {
    private func inboxTemplate() -> Note {
        Note(title: "Agent Inbox", color: .graphite, material: .glass, kind: .agentInbox)
    }

    @Test("ensureAgentInboxNote inserts once and returns the same row afterwards")
    func ensureIsIdempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        let first = try await db.ensureAgentInboxNote(inboxTemplate())
        let second = try await db.ensureAgentInboxNote(Note(title: "Other", kind: .list))

        #expect(first.id == second.id)
        #expect(second.kind == .agentInbox)
        #expect(second.title == "Agent Inbox")
        #expect(try await db.note(id: first.id)?.kind == .agentInbox)
    }

    @Test("a closed inbox note is kept, not recreated")
    func closedInboxIsKept() async throws {
        let db = try AppDatabase.makeInMemory()
        let inbox = try await db.ensureAgentInboxNote(inboxTemplate())
        try await db.updateNoteOpen(id: inbox.id, isOpen: false)

        let again = try await db.ensureAgentInboxNote(inboxTemplate())
        #expect(again.id == inbox.id)
        #expect(!again.isOpen)
    }

    @Test("lists queries leave the inbox out, launch restore keeps it")
    func listsExcludeInbox() async throws {
        let db = try AppDatabase.makeInMemory()
        let inbox = try await db.ensureAgentInboxNote(inboxTemplate())
        let list = try await db.insertNewNote(Note())

        #expect(try await db.allNotes().map(\.id) == [list.id])
        #expect(try await db.openNotes().map(\.id).sorted { $0.uuidString < $1.uuidString }
            == [inbox.id, list.id].sorted { $0.uuidString < $1.uuidString })

        var observed: [Note] = []
        for try await notes in db.observeNotes() {
            observed = notes
            break
        }
        #expect(observed.map(\.id) == [list.id])
    }

    @Test("new list names count lists only")
    func namingIgnoresInbox() async throws {
        let db = try AppDatabase.makeInMemory()
        _ = try await db.ensureAgentInboxNote(inboxTemplate())
        let list = try await db.insertNewNote(Note())
        #expect(list.title == "List 1")
    }

    @Test("the inbox note never enters the sync record")
    func syncSkipsInbox() async throws {
        let db = try AppDatabase.makeInMemory()
        let inbox = try await db.ensureAgentInboxNote(inboxTemplate())
        let list = try await db.insertNewNote(Note())

        let local = try await db.dbQueue.write { try AppDatabase.syncLocal($0) }
        #expect(local.notes[inbox.id.uuidString] == nil)
        #expect(local.notes[list.id.uuidString] != nil)
    }

    @Test("MCP tools can't see or change the inbox note")
    @MainActor
    func mcpHidesInbox() async throws {
        let db = try AppDatabase.makeInMemory()
        let tools = MCPTools(database: db, window: .init(open: { _ in }, close: { _ in }, setFrame: { _, _ in }, focus: { _ in }))
        let inbox = try await db.ensureAgentInboxNote(inboxTemplate())

        let listed = await tools.call("list_notes", [:])
        #expect(!text(listed).contains(inbox.id.uuidString))

        for name in ["get_note", "delete_note", "focus_note"] {
            let result = await tools.call(name, ["note_id": .string(inbox.id.uuidString)])
            #expect(result.isError == true, "\(name) should refuse the inbox note")
        }
        let added = await tools.call("add_tasks", ["note_id": .string(inbox.id.uuidString), "tasks": .array([.string("x")])])
        #expect(added.isError == true)
        #expect(try await db.note(id: inbox.id) != nil)
        #expect(try await db.tasks(noteId: inbox.id).isEmpty)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case let .text(t, _, _) = $0 { return t } else { return nil } }.joined()
    }
}
