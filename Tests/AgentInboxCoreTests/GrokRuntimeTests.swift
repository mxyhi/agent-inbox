import Darwin
import Foundation
import Testing
@testable import AgentInboxCore

private struct RuntimeFixture {
    let root: URL
    let session: URL
    let active: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        session = root.appending(path: "sessions/project/conversation")
        active = root.appending(path: "active_sessions.json")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try write("summary.json", #"{"info":{"id":"conversation","cwd":"/tmp/project"},"generated_title":"工作","num_chat_messages":4}"#)
        try Data("[{\"session_id\":\"conversation\",\"pid\":\(getpid())}]".utf8).write(to: active)
        try write("events.jsonl", #"{"type":"turn_ended","outcome":"completed"}"# + "\n")
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: session.appending(path: name))
    }

    func append(_ name: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: session.appending(path: name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func monitor(startedAt: Date = .distantPast, maxFiles: Int = 80) -> GrokSessionMonitor {
        GrokSessionMonitor(sessionsRoot: root.appending(path: "sessions"), activeSessionsFile: active, maxFiles: maxFiles,
            inspectProcess: { pid in
                pid == getpid() ? GrokProcessSnapshot(startedAt: startedAt,
                    openFiles: [session.appending(path: "events.jsonl").standardizedFileURL.path]) : nil
            })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private let runningMonitor = #"{"params":{"update":{"sessionUpdate":"background_tasks","tasks":[{"task_id":"monitor-1","kind":"monitor","status":"running"}]}}}"# + "\n"

@Test func grokCachedScheduleStillExpiresWithoutAnyFileWrite() throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("resources_state.json", #"{"state":{"grok_build.Scheduler":{"tasks":[{"id":"loop","expiresAt":"2026-10-06T01:00:00Z"}]},"unrelated":{"state":[1,"text",false]}}}"#)
    let state = GrokRuntimeState()
    let host = GrokProcessSnapshot(startedAt: .distantPast, openFiles: [])
    let expiry = try #require(ISO8601DateFormatter().date(from: "2026-10-06T01:00:00Z"))
    #expect(try state.backgroundCount(at: fixture.session, host: host, now: expiry.addingTimeInterval(-1)) == 1)
    #expect(try state.backgroundCount(at: fixture.session, host: host, now: expiry) == 0)
    try FileManager.default.removeItem(at: fixture.session.appending(path: "resources_state.json"))
    #expect(try state.backgroundCount(at: fixture.session, host: host, now: expiry.addingTimeInterval(-1)) == 0)
}

@Test func grokPromptCacheInvalidatesOnAppendReplacementAndDeletion() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let first = #"{"params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"old"}}}}"# + "\n"
    try fixture.write("updates.jsonl", first)
    let monitor = fixture.monitor()
    #expect(await monitor.scan().first?.lastAgentMessage == "old")
    let file = fixture.session.appending(path: "updates.jsonl")
    let stamp = try #require(GrokFileStamp(file))
    // 同大小、同mtime的原子替换也必须失效，不能只看时间戳。
    try Data(first.replacingOccurrences(of: "old", with: "new").utf8).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: stamp.modifiedAt], ofItemAtPath: file.path)
    #expect(await monitor.scanChangedPaths([file.path]).first?.lastAgentMessage == "new")
    try fixture.append("updates.jsonl", first)
    #expect(await monitor.scanChangedPaths([file.path]).first?.lastAgentMessage == "newold")
    try FileManager.default.removeItem(at: file)
    #expect(await monitor.scanChangedPaths([file.path]).first?.lastAgentMessage == "工作")
}

@Test func grokDiscoveryDoesNotTreatCheckpointCopiesAsSessions() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let checkpoint = fixture.session.appending(path: "checkpoints/old")
    try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
    try Data(#"{"info":{"id":"checkpoint-copy"}}"#.utf8).write(to: checkpoint.appending(path: "summary.json"))
    #expect(await fixture.monitor().scan().map(\.sessionID) == ["conversation"])
}

@Test func grokBackgroundWorkSurvivesTurnEndAndEndsOnTaskCompletion() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("updates.jsonl", runningMonitor)
    let monitor = fixture.monitor()
    let first = try #require(await monitor.scan().first)
    #expect(first.lifecycleState == .running)
    #expect(first.taskCompletedAt == nil)
    try fixture.append("updates.jsonl", #"{"params":{"update":{"sessionUpdate":"task_completed","task_snapshot":{"task_id":"monitor-1","completed":true}}}}"# + "\n")
    let next = try #require(await monitor.scanChangedPaths([fixture.session.appending(path: "updates.jsonl").path]).first)
    #expect(next.lifecycleState == .completed)
}

@Test func grokScheduledLoopKeepsConversationRunningUntilDeletedOrExpired() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("resources_state.json", #"{"state":{"grok_build.Scheduler":{"tasks":[{"id":"loop","recurring":true,"expiresAt":"2099-01-01T00:00:00Z"}]}}}"#)
    let monitor = fixture.monitor()
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.write("resources_state.json", #"{"state":{"grok_build.Scheduler":{"tasks":[]}}}"#)
    #expect(await monitor.scanChangedPaths([fixture.session.appending(path: "resources_state.json").path]).first?.lifecycleState == .completed)
    try fixture.write("resources_state.json", #"{"state":{"grok_build.Scheduler":{"tasks":[{"id":"expired","expiresAt":"2000-01-01T00:00:00Z"}]}}}"#)
    #expect(await monitor.scan().first?.lifecycleState == .completed)
}

@Test func grokSilentWorkDoesNotExpireAfterTwoMinutes() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("events.jsonl", #"{"type":"turn_started"}"# + "\n")
    let old = Date().addingTimeInterval(-600)
    for name in ["events.jsonl", "summary.json"] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: fixture.session.appending(path: name).path)
    }
    let summaries = await fixture.monitor().scan()
    #expect(summaries.first?.modifiedAt == old)
    #expect(AgentStatusResolver().resolve(summaries: summaries, completedSessionIDs: []).running.count == 1)
}

@Test func grokReadsLifecycleOutsideTailAndResetsAfterRewrite() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("events.jsonl", #"{"type":"turn_started"}"# + "\n" + String(repeating: #"{"type":"phase_changed","phase":"waiting_for_model"}"# + "\n", count: 4000))
    let monitor = fixture.monitor()
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.write("events.jsonl", #"{"type":"turn_ended","outcome":"aborted"}"# + "\n")
    #expect(await monitor.scan().first?.lifecycleState == .aborted)
}

@Test func grokIdleProcessDoesNotBecomeRunning() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    #expect(await fixture.monitor().scan().first?.lifecycleState == .completed)
    try fixture.write("events.jsonl", "")
    #expect(await fixture.monitor().scan().first?.lifecycleState == .unknown)
}

@Test func grokUsesAttachedSessionInsteadOfStaleRegistryIdentity() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try Data("[{\"session_id\":\"old-startup-session\",\"pid\":\(getpid())}]".utf8).write(to: fixture.active)
    try fixture.write("events.jsonl", #"{"type":"turn_started"}"# + "\n")
    let monitor = fixture.monitor()
    let summary = try #require(await monitor.scan().first)
    #expect(summary.sessionID == "conversation")
    #expect(summary.runtimeVerified == true)
    #expect(summary.lifecycleState == .running)
    // 宿主关闭，文件仍留在磁盘，也必须撤销运行状态。
    try Data("[]".utf8).write(to: fixture.active)
    let detached = try #require(await monitor.scanChangedPaths([fixture.active.path]).first)
    #expect(detached.runtimeVerified == false)
    #expect(detached.lifecycleState == .unknown)
}

@Test func grokDoesNotReportOldBackgroundRecordsAfterHostRestart() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("updates.jsonl", #"{"params":{"update":{"sessionUpdate":"background_tasks","tasks":[{"task_id":"old","kind":"monitor","status":"running","started_at":"2000-01-01T00:00:00Z"}]}}}"# + "\n")
    let summary = try #require(await fixture.monitor(startedAt: Date()).scan().first)
    #expect(summary.lifecycleState == .unknown)
    #expect(summary.taskCompletedAt == nil)
    #expect(summary.backgroundTaskCount == 0)
    #expect(GrokProcessSnapshot.read(pid: getpid()) == nil) // 测试进程不是 Grok，不能借用登记 PID。
}

@Test func grokSubagentUpdatesRefreshOnlyTheParentAndMatchAttempt() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let child = fixture.session.appending(path: "subagents/child/meta.json")
    try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"status":"running","attempt_id":"second","started_at":"2026-10-06T00:00:00Z"}"#.utf8).write(to: child)
    try fixture.write("updates.jsonl", #"{"params":{"update":{"sessionUpdate":"subagent_spawned","subagent_id":"child","attempt_id":"second"}}}"# + "\n")
    let monitor = fixture.monitor()
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.append("updates.jsonl", #"{"params":{"update":{"sessionUpdate":"subagent_finished","subagent_id":"child","attempt_id":"first","status":"completed"}}}"# + "\n")
    #expect(await monitor.scan().first?.lifecycleState == .running)
    // meta 先于父事件落盘也应马上反映到父会话，不能等 summary/events 改动。
    try Data(#"{"status":"completed","attempt_id":"second","started_at":"2026-10-06T00:00:00Z","completed_at":"2026-10-06T00:01:00Z"}"#.utf8).write(to: child)
    let summaries = await monitor.scanChangedPaths([child.path])
    #expect(summaries.count == 1)
    #expect(summaries.first?.lifecycleState == .completed)
}

@Test func grokPendingPermissionTakesPriorityOverBackgroundWork() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("updates.jsonl", runningMonitor)
    try fixture.write("events.jsonl", """
    {"type":"turn_started","ts":"2026-10-06T00:00:00Z"}
    {"type":"permission_requested","ts":"2026-10-06T00:00:01Z","tool_name":"run_terminal_command"}

    """)
    let monitor = fixture.monitor()
    let request = try #require(await monitor.scan().first)
    #expect(request.lifecycleState == .waitingForUser)
    #expect(request.pendingRequestID == "permission:2026-10-06T00:00:01Z:run_terminal_command")
    #expect(request.backgroundTaskCount == 1)
    try fixture.append("events.jsonl", #"{"type":"permission_resolved","tool_name":"run_terminal_command"}"# + "\n")
    #expect(await monitor.scan().first?.lifecycleState == .running)
}

@Test func grokPartialUpdatesAndReplacementDoNotResurrectTasks() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("updates.jsonl", runningMonitor)
    let monitor = fixture.monitor()
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.append("updates.jsonl", #"{"params":{"update":{"sessionUpdate":"task_completed","task_snapshot":{"task_id":"monitor-1","completed":true}"#)
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.append("updates.jsonl", "}}}\n")
    #expect(await monitor.scan().first?.lifecycleState == .completed)
    try Data(runningMonitor.utf8).write(to: fixture.session.appending(path: "updates.jsonl"), options: .atomic)
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.write("updates.jsonl", "")
    #expect(await monitor.scan().first?.lifecycleState == .completed)
}

@Test func grokActiveSessionsAreRetainedOutsideHistoryWindow() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("updates.jsonl", runningMonitor)
    let old = Date().addingTimeInterval(-86400)
    for name in ["events.jsonl", "summary.json"] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: fixture.session.appending(path: name).path)
    }
    let newer = fixture.root.appending(path: "sessions/project/newer")
    try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
    try Data(#"{"info":{"id":"newer"},"generated_title":"history","num_chat_messages":4}"#.utf8).write(to: newer.appending(path: "summary.json"))
    let summaries = await fixture.monitor(maxFiles: 1).scan()
    #expect(summaries.contains { $0.sessionID == "conversation" && $0.lifecycleState == .running })
    #expect(summaries.contains { $0.sessionID == "newer" && $0.runtimeVerified == false })
}

@Test func grokDeletedSchedulerEventOverridesStaleResourceFile() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("resources_state.json", #"{"state":{"grok_build.Scheduler":{"tasks":[{"id":"loop","expiresAt":"2099-01-01T00:00:00Z"}]}}}"#)
    let monitor = fixture.monitor()
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.write("updates.jsonl", #"{"params":{"update":{"sessionUpdate":"scheduled_task_deleted","task_id":"loop"}}}"# + "\n")
    #expect(await monitor.scan().first?.lifecycleState == .completed)
}

@Test func grokLongOutputDoesNotHideTaskStateAndCompletionUsesBackgroundTime() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("events.jsonl", #"{"type":"turn_ended","outcome":"completed","ts":"2026-10-06T00:00:00Z"}"# + "\n")
    let hugeOutput = String(repeating: "日志内容", count: 200_000)
    let message = try JSONSerialization.data(withJSONObject: ["params": ["update": ["sessionUpdate": "agent_message_chunk", "content": ["text": hugeOutput]]]])
    try fixture.write("updates.jsonl", runningMonitor + String(decoding: message, as: UTF8.self) + "\n")
    let monitor = fixture.monitor()
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.append("updates.jsonl", #"{"timestamp":"2026-10-06T04:00:00Z","params":{"update":{"sessionUpdate":"task_completed","task_snapshot":{"task_id":"monitor-1","completed":true}}}}"# + "\n")
    let final = try #require(await monitor.scan().first)
    #expect(final.lifecycleState == .completed)
    #expect(final.taskCompletedAt == ISO8601DateFormatter().date(from: "2026-10-06T04:00:00Z"))
}

@Test func grokQuestionDoesNotSurviveItsAnswerOrANewPrompt() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    try fixture.write("events.jsonl", #"{"type":"turn_started"}"# + "\n")
    let question = #"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"question-1","rawInput":{"variant":"AskUserQuestion"}}}}"# + "\n"
    try fixture.write("updates.jsonl", question)
    let monitor = fixture.monitor()
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    try fixture.append("updates.jsonl", #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"question-1","status":"completed"}}}"# + "\n")
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.append("updates.jsonl", question)
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    try fixture.append("updates.jsonl", #"{"params":{"update":{"sessionUpdate":"user_message_chunk","content":{"text":"换个任务"}}}}"# + "\n")
    #expect(await monitor.scan().first?.lifecycleState == .running)
}
