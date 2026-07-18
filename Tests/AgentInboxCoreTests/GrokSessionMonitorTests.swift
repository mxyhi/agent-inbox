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

/// fixture 时间必须落在 todo retention(24h) 内,用相对 now 的 ISO8601
private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
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
func grokMonitorMarksEndedTurnWhileProcessAliveAsWaitingForNextPrompt() async throws {
    let root = try makeGrokFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let started = iso8601(now.addingTimeInterval(-60))
    let ended = iso8601(now.addingTimeInterval(-10))
    let sessionID = "019f-test-idle"
    let cwd = "/tmp/grok-idle"
    _ = try writeGrokSession(
        root: root,
        sessionID: sessionID,
        cwd: cwd,
        summaryBody: """
        {"info":{"id":"\(sessionID)","cwd":"\(cwd)"},"created_at":"\(started)","updated_at":"\(ended)","last_active_at":"\(ended)","generated_title":"Idle","num_chat_messages":4}
        """,
        eventsBody: """
        {"ts":"\(started)","type":"turn_started"}
        {"ts":"\(ended)","type":"turn_ended","outcome":"completed"}
        """,
        updatesBody: """
        {"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"继续改"}}}}
        {"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"改完了,等你指示"}}}}
        """
    )
    // 进程仍活:交互式 TUI 常态,正是「等下一步提示」要提醒的时刻
    let activeFile = try writeActiveSessions(root: root, records: [
        ["session_id": sessionID, "pid": Int(getpid()), "cwd": cwd]
    ])

    let monitor = GrokSessionMonitor(sessionsRoot: root, activeSessionsFile: activeFile)
    let summary = try #require(await monitor.scan().first)

    #expect(summary.lifecycleState == .completed)
    #expect(summary.taskCompletedAt != nil)
    #expect(summary.lastAgentMessage == "改完了,等你指示")

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
func grokMonitorMarksDeadProcessWithCompletedTurnAsTodoCandidate() async throws {
    let root = try makeGrokFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let started = iso8601(now.addingTimeInterval(-120))
    let ended = iso8601(now.addingTimeInterval(-30))
    let sessionID = "019f-test-todo"
    let cwd = "/tmp/grok-todo"
    _ = try writeGrokSession(
        root: root,
        sessionID: sessionID,
        cwd: cwd,
        summaryBody: """
        {"info":{"id":"\(sessionID)","cwd":"\(cwd)"},"created_at":"\(started)","updated_at":"\(ended)","last_active_at":"\(ended)","generated_title":"Done work","num_chat_messages":6}
        """,
        eventsBody: """
        {"ts":"\(started)","type":"turn_started"}
        {"ts":"\(ended)","type":"turn_ended","outcome":"completed"}
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
