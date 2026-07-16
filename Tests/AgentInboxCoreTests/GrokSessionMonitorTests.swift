import Darwin
import Foundation
import Testing
@testable import AgentInboxCore

/// Grok monitor fixture:构造最小 session 目录树
private func makeGrokFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "agent-inbox-grok-tests")
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeGrokSession(
    root: URL,
    sessionID: String,
    cwd: String,
    summaryBody: String,
    eventsBody: String,
    updatesBody: String = ""
) throws -> URL {
    let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd
    let dir = root.appending(path: encoded).appending(path: sessionID)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try summaryBody.write(to: dir.appending(path: "summary.json"), atomically: true, encoding: .utf8)
    try eventsBody.write(to: dir.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
    if !updatesBody.isEmpty {
        try updatesBody.write(to: dir.appending(path: "updates.jsonl"), atomically: true, encoding: .utf8)
    }
    return dir
}

private func writeActiveSessions(root: URL, records: [[String: Any]]) throws -> URL {
    let file = root.appending(path: "active_sessions.json")
    let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted])
    try data.write(to: file)
    return file
}

@Test
func grokMonitorMarksMidTurnAliveProcessAsRunning() async throws {
    let root = try makeGrokFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "019f-test-running"
    let cwd = "/tmp/grok-project"
    _ = try writeGrokSession(
        root: root,
        sessionID: sessionID,
        cwd: cwd,
        summaryBody: """
        {"info":{"id":"\(sessionID)","cwd":"\(cwd)"},"created_at":"2026-07-15T12:00:00.000Z","updated_at":"2026-07-15T12:05:00.000Z","last_active_at":"2026-07-15T12:05:00.000Z","generated_title":"Running task","num_chat_messages":4}
        """,
        eventsBody: """
        {"ts":"2026-07-15T12:00:01.000Z","type":"turn_started","session_id":"\(sessionID)"}
        {"ts":"2026-07-15T12:00:02.000Z","type":"phase_changed","phase":"streaming_text"}
        """,
        updatesBody: """
        {"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"实现功能"}}}}
        """
    )

    // 用当前进程 pid 模拟存活
    let activeFile = try writeActiveSessions(root: root, records: [
        ["session_id": sessionID, "pid": Int(getpid()), "cwd": cwd, "opened_at": "2026-07-15T12:00:00.000Z"]
    ])

    let monitor = GrokSessionMonitor(sessionsRoot: root, activeSessionsFile: activeFile)
    let summary = try #require(await monitor.scan().first)

    #expect(summary.provider == .grok)
    #expect(summary.sessionID == sessionID)
    #expect(summary.id == "grok:\(sessionID)")
    #expect(summary.lifecycleState == .running)
    #expect(summary.taskCompletedAt == nil)
    #expect(summary.firstPrompt == "实现功能")
    #expect(summary.cwd == cwd)
}

@Test
func grokMonitorHidesEndedTurnWhileProcessAlive() async throws {
    let root = try makeGrokFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "019f-test-idle"
    let cwd = "/tmp/grok-idle"
    _ = try writeGrokSession(
        root: root,
        sessionID: sessionID,
        cwd: cwd,
        summaryBody: """
        {"info":{"id":"\(sessionID)","cwd":"\(cwd)"},"created_at":"2026-07-15T12:00:00.000Z","updated_at":"2026-07-15T12:05:00.000Z","last_active_at":"2026-07-15T12:05:00.000Z","generated_title":"Idle","num_chat_messages":4}
        """,
        eventsBody: """
        {"ts":"2026-07-15T12:00:01.000Z","type":"turn_started"}
        {"ts":"2026-07-15T12:00:10.000Z","type":"turn_ended","outcome":"completed"}
        """
    )
    let activeFile = try writeActiveSessions(root: root, records: [
        ["session_id": sessionID, "pid": Int(getpid()), "cwd": cwd]
    ])

    let monitor = GrokSessionMonitor(sessionsRoot: root, activeSessionsFile: activeFile)
    let summary = try #require(await monitor.scan().first)

    // 进程仍活 + turn 已结束 = 等用户输入,不进 running/todo
    #expect(summary.lifecycleState == .unknown)
    #expect(summary.taskCompletedAt == nil)
}

@Test
func grokMonitorMarksDeadProcessWithCompletedTurnAsTodoCandidate() async throws {
    let root = try makeGrokFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "019f-test-todo"
    let cwd = "/tmp/grok-todo"
    _ = try writeGrokSession(
        root: root,
        sessionID: sessionID,
        cwd: cwd,
        summaryBody: """
        {"info":{"id":"\(sessionID)","cwd":"\(cwd)"},"created_at":"2026-07-15T12:00:00.000Z","updated_at":"2026-07-15T12:05:00.000Z","last_active_at":"2026-07-15T12:05:00.000Z","generated_title":"Done work","num_chat_messages":6}
        """,
        eventsBody: """
        {"ts":"2026-07-15T12:00:01.000Z","type":"turn_started"}
        {"ts":"2026-07-15T12:00:10.000Z","type":"turn_ended","outcome":"completed"}
        """,
        updatesBody: """
        {"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"修 bug"}}}}
        {"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"已修复"}}}}
        """
    )
    // 死 pid:用极大不可能存活的 pid
    let activeFile = try writeActiveSessions(root: root, records: [
        ["session_id": sessionID, "pid": 2_147_483_646, "cwd": cwd]
    ])

    let monitor = GrokSessionMonitor(sessionsRoot: root, activeSessionsFile: activeFile)
    let summary = try #require(await monitor.scan().first)

    #expect(summary.lifecycleState == .completed)
    #expect(summary.taskCompletedAt != nil)
    #expect(summary.firstPrompt == "修 bug")
    #expect(summary.lastAgentMessage == "已修复")

    // 进入 resolver 后应成为待办
    let now = Date()
    let snapshot = AgentStatusResolver().resolve(
        summaries: [summary],
        completedSessionIDs: [],
        trackingStartedAt: .distantPast,
        now: now
    )
    #expect(snapshot.todos.map(\.id) == ["grok:\(sessionID)"])
    #expect(snapshot.running.isEmpty)
}

@Test
func grokMonitorIgnoresZombiePidInActiveSessions() async throws {
    let root = try makeGrokFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "019f-test-zombie"
    let cwd = "/tmp/grok-zombie"
    _ = try writeGrokSession(
        root: root,
        sessionID: sessionID,
        cwd: cwd,
        summaryBody: """
        {"info":{"id":"\(sessionID)","cwd":"\(cwd)"},"created_at":"2026-07-15T12:00:00.000Z","updated_at":"2026-07-15T12:01:00.000Z","last_active_at":"2026-07-15T12:01:00.000Z","generated_title":"Zombie","num_chat_messages":3}
        """,
        eventsBody: """
        {"ts":"2026-07-15T12:00:01.000Z","type":"turn_started"}
        """
    )
    // mid-turn + 死 pid → 不展示 running
    let activeFile = try writeActiveSessions(root: root, records: [
        ["session_id": sessionID, "pid": 2_147_483_645, "cwd": cwd]
    ])

    let monitor = GrokSessionMonitor(sessionsRoot: root, activeSessionsFile: activeFile)
    let summary = try #require(await monitor.scan().first)
    #expect(summary.lifecycleState == .unknown)
}

@Test
func sessionIdentityNormalizesLegacyCompletedIDs() {
    #expect(SessionIdentity.normalizeCompletedID("abc") == "codex:abc")
    #expect(SessionIdentity.normalizeCompletedID("codex:abc") == "codex:abc")
    #expect(SessionIdentity.normalizeCompletedID("grok:uuid") == "grok:uuid")
    #expect(SessionIdentity.key(provider: .grok, sessionID: "x") == "grok:x")
}
