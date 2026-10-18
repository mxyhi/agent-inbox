import Darwin
import Foundation
import Testing
@testable import AgentInboxCore

@Test
func dshCompletedTurnUsesEventTimeAndNativeIdentity() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    let file = try fixture.write("main", events: [
        dshEvent("turn/start", seq: 0),
        dshEvent("user/message", seq: 1, data: ["source": ["kind": "user"], "content": dshText("支持 DSH\n详细说明")]),
        dshEvent("assistant/message", seq: 2, data: ["message": ["content": dshText("已实现并验证")]]),
        dshEnd(seq: 3)
    ])
    let monitor = DshSessionMonitor(sessionsRoot: fixture.root)
    let summary = try #require(await monitor.scan().first)
    #expect(summary.provider == .dsh)
    #expect(summary.id == "dsh:main")
    #expect(summary.cwd == "/tmp/dsh")
    #expect(summary.firstPrompt == "支持 DSH")
    #expect(summary.lastAgentMessage == "已实现并验证")
    #expect(summary.lifecycleState == .completed)
    #expect(summary.taskCompletedAt == Date(timeIntervalSince1970: 1_792_224_003))
    #expect(summary.taskCompletedAt != summary.modifiedAt)
    #expect(SessionIdentity.normalizeCompletedID(summary.id) == summary.id)
    try OpenSessionExecutor().execute(session: summary, config: OpenSessionConfig(
        method: .custom, customCommand: "test \"$provider\" = dsh && test \"$session_id\" = main"
    ))

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: dshEvent("turn/start", seq: 4))
    try handle.close()
    let resumed = try #require(await monitor.scanChangedPaths([file.path]).first)
    #expect(resumed.lifecycleState == .running)
    #expect(resumed.taskCompletedAt == nil)
    #expect(resumed.lastAgentMessage == nil)
}

@Test(arguments: ["aborted", "error", "interrupted", "max-tokens"])
func dshUnsuccessfulEndDoesNotProduceCompletion(reason: String) async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    try fixture.write("stopped", events: [dshEvent("turn/start", seq: 0), dshEnd(seq: 1, reason: reason)])
    let summary = try #require(await DshSessionMonitor(sessionsRoot: fixture.root).scan().first)
    #expect(summary.lifecycleState == .aborted)
    #expect(summary.taskCompletedAt == nil)
}

@Test
func dshQuestionSurvivesToolTimeoutCompletionAndRestartUntilMatchingReply() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    let events = [
        dshEvent("turn/start", seq: 0),
        dshQuestion(seq: 1, id: "question-1", text: "选择部署方式"),
        dshEvent("tool/result", seq: 2, data: ["message": ["toolCallId": "question-1", "content": dshText("{\"pending\":true}")]]),
        dshEnd(seq: 3),
        dshEvent("user/message", seq: 4, data: ["source": ["kind": "user"], "content": dshText("另一个提示")])
    ]
    let file = try fixture.write("question", events: events)
    let first = try #require(await DshSessionMonitor(sessionsRoot: fixture.root).scan().first)
    let monitor = DshSessionMonitor(sessionsRoot: fixture.root)
    let restarted = try #require(await monitor.scan().first)
    #expect(first.lifecycleState == .waitingForUser)
    #expect(first.pendingQuestion == "选择部署方式")
    #expect(first.pendingRequestID == "question-1")
    #expect(restarted.requestAcknowledgementID == first.requestAcknowledgementID)
    #expect(AgentStatusResolver().resolve(
        summaries: [restarted], completedSessionIDs: [],
        acknowledgedRequests: [first.id: first.requestAcknowledgementID]
    ).todos.isEmpty)

    try fixture.write("question", events: events + [
        dshQuestion(seq: 5, id: "question-2", text: "确认新的选择"),
        dshEvent("user/message", seq: 6, data: ["source": ["kind": "user-question-reply", "callId": "question-1"]])
    ])
    let newer = try #require(await monitor.scanChangedPaths([file.path]).first)
    #expect(newer.pendingRequestID == "question-2")
    #expect(newer.pendingQuestion == "确认新的选择")

    try fixture.write("question", events: events + [
        dshEvent("user/message", seq: 5, data: ["source": ["kind": "user-question-reply", "callId": "question-1"]]),
        dshEvent("turn/start", seq: 6)
    ])
    let replied = try #require(await monitor.scanChangedPaths([file.path]).first)
    #expect(replied.lifecycleState == .running)
    #expect(replied.pendingRequestID == nil)
}

@Test
func dshBlockingQuestionClearsOnToolResult() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    try fixture.write("answered", events: [
        dshEvent("turn/start", seq: 0), dshQuestion(seq: 1, id: "ask", text: "继续吗？"),
        dshEvent("tool/result", seq: 2, data: ["message": ["toolCallId": "ask", "content": dshText("{\"answers\":[]}")]])
    ])
    let summary = try #require(await DshSessionMonitor(sessionsRoot: fixture.root).scan().first)
    #expect(summary.lifecycleState == .running)
    #expect(summary.pendingQuestion == nil)
}

@Test
func dshForkDoesNotInheritParentCompletionQuestionOrSubagentIdentity() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    try fixture.write("fork", events: [
        dshEvent("subagent/descriptor", seq: 0), dshQuestion(seq: 1, id: "parent-ask", text: "旧问题"),
        dshEnd(seq: 2), dshEvent("session/end-seed", seq: 3, data: ["inherited": true]),
        dshEvent("turn/start", seq: 4)
    ], seeded: true)
    try fixture.write("child", events: [dshEnd(seq: 0)], child: true)
    try fixture.write("descriptor-child", events: [dshEvent("subagent/descriptor", seq: 0), dshEnd(seq: 1)])
    let summaries = await DshSessionMonitor(sessionsRoot: fixture.root).scan()
    #expect(summaries.map(\.sessionID) == ["fork"])
    #expect(summaries.first?.lifecycleState == .running)
    #expect(summaries.first?.pendingQuestion == nil)
}

@Test
func dshLiveChildKeepsParentRunningAndEmptyLockDoesNot() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    try fixture.write("parent", events: [
        dshEvent("turn/start", seq: 0),
        dshEvent("subagent/catalog", seq: 1, data: ["childId": "child"]), dshEnd(seq: 2)
    ])
    let child = try fixture.write("child", events: [dshEvent("turn/start", seq: 0)], child: true)
    let lock = child.deletingLastPathComponent().appending(path: "session.lock")
    try Data().write(to: lock)
    let descriptor = open(lock.path, O_RDONLY)
    defer { close(descriptor) }
    #expect(descriptor >= 0)
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    let monitor = DshSessionMonitor(sessionsRoot: fixture.root)
    let working = try #require(await monitor.scan().first)
    #expect(working.id == "dsh:parent")
    #expect(working.lifecycleState == .running)
    #expect(working.runtimeVerified == true)
    #expect(working.backgroundTaskCount == 1)
    #expect(working.taskCompletedAt == nil)
    #expect(flock(descriptor, LOCK_UN) == 0)
    let done = try #require(await monitor.scanChangedPaths([lock.path]).first)
    #expect(done.lifecycleState == .completed)
    #expect(done.runtimeVerified == false)
}

@Test
func dshIncrementalScanHandlesCreationDeletionAndUnrelatedPaths() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    let file = try fixture.write("first", events: [dshEnd(seq: 0)])
    let monitor = DshSessionMonitor(sessionsRoot: fixture.root)
    #expect(await monitor.scan().count == 1)
    #expect(await monitor.scanChangedPaths(["/tmp/unrelated"]).count == 1)
    let second = try fixture.write("second", events: [dshEnd(seq: 0)])
    #expect(await monitor.scanChangedPaths([second.path]).count == 2)
    try FileManager.default.removeItem(at: file)
    #expect(await monitor.scanChangedPaths([file.path]).map(\.sessionID) == ["second"])
    try FileManager.default.removeItem(at: fixture.root)
    #expect(await monitor.scanChangedPaths([fixture.root.path]).isEmpty)
}

@Test
func dshIgnoresUncommittedTailAndRejectsCorruptOrFutureLogs() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    let partial = Data("{\"type\":\"turn/end\"".utf8)
    try fixture.write("partial", events: [dshEvent("turn/start", seq: 0), partial])
    try fixture.write("corrupt", events: [Data("broken\n".utf8)])
    try fixture.write("future", events: [dshEnd(seq: 0)], version: 5)
    let summaries = await DshSessionMonitor(sessionsRoot: fixture.root).scan()
    #expect(summaries.map(\.sessionID) == ["partial"])
    #expect(summaries.first?.lifecycleState == .running)
}

@Test
func dshReadsConcatenatedZstandardFrames() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    let base64 = "KLUv/SCOpQMA8oYXG4C5OfhGWKwsGa8t+oleJxZRjGPeoBRINjVVD4AGgsnKuheaxlYhvjyN57qow/M3KFM0D8fsoVjGgyQIoYEggMlLyK/6W3nVP8e0lcx4EkzvCeNx05jq1Zh8t1gzAgcAO8NIFZyq03DNilok1OJYKGMotS/9IE1pAgB7InR5cGUiOiAidHVybi9zdGFydCIsICJzZXEiOiAwLCAidGltZSI6IDE3OTIyMjQwMDAwMDAsICJkYXRhIjogeyJ0dXJuIjogMX19Cii1L/0gbOUCAIIFExhwSdxUH0JGadWEG6b/HxYTtyZzk/9zvRfFe+/LzYaFFOGo33QKd6oZZg71ps0eR2aSzEApZSAg6PRxENQfuB3HNzEgMUQf9bwSfRcEADCDOpWBrHosrIoM"
    let plaintext = try fixture.write("compressed", events: [])
    let compressed = plaintext.appendingPathExtension("zstd")
    try #require(Data(base64Encoded: base64)).write(to: compressed)
    let monitor = DshSessionMonitor(sessionsRoot: fixture.root)
    let summary = try #require(await monitor.scan().first)
    #expect(summary.id == "dsh:compressed")
    #expect(summary.lifecycleState == .completed)
    #expect(summary.taskCompletedAt == Date(timeIntervalSince1970: 1_792_224_001))
    #expect(summary.filePath == compressed.resolvingSymlinksInPath().path)
    let fullBytes = await monitor.lastDecodedBytes
    let nextFrame = try #require(Data(base64Encoded: "KLUv/SBNNQIAQsQOFZA7B9xisr1SDSh3Zyq1JwjkyXhEXUBrL5oVjRIZ7rm73w3/C0JAjnTPi17Sco9ToVxBoph00Ulp0iwCAGwloyNQZA=="))
    let handle = try FileHandle(forWritingTo: compressed)
    try handle.seekToEnd()
    try handle.write(contentsOf: nextFrame)
    try handle.close()
    let resumed = try #require(await monitor.scanChangedPaths([compressed.path]).first)
    #expect(resumed.lifecycleState == .running)
    #expect(await monitor.lastDecodedBytes < fullBytes)
    _ = await monitor.scan()
    #expect(await monitor.lastDecodedBytes == 0)
}

@Test
func dshAppendCostDoesNotGrowWithHistoryAndPartialLineIsReplayed() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    var events = (0..<2_000).map { dshEvent("request/header", seq: $0, data: ["padding": String(repeating: "x", count: 200)]) }
    events.append(dshEvent("turn/start", seq: 2_000))
    let end = dshEnd(seq: 2_001)
    events.append(end.prefix(end.count / 2))
    let file = try fixture.write("large", events: events)
    let monitor = DshSessionMonitor(sessionsRoot: fixture.root)
    #expect(await monitor.scan().first?.lifecycleState == .running)
    #expect(await monitor.lastDecodedBytes > 400_000)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: end.suffix(from: end.count / 2))
    try handle.close()
    #expect(await monitor.scanChangedPaths([file.path]).first?.lifecycleState == .completed)
    #expect(await monitor.lastDecodedBytes < 512)
    _ = await monitor.scan()
    #expect(await monitor.lastDecodedBytes == 0)
}

@Test
func compositeMonitorIncludesDshAndItsWatchRoot() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    let file = try fixture.write("composite", events: [dshEnd(seq: 0)])
    let monitor = CompositeSessionMonitor(
        codex: CodexSessionMonitor(sessionsRoot: fixture.root.appending(path: "missing-codex")),
        grok: GrokSessionMonitor(sessionsRoot: fixture.root.appending(path: "missing-grok"), activeSessionsFile: fixture.root.appending(path: "missing-active")),
        claude: ClaudeSessionMonitor(sessionsRoot: fixture.root.appending(path: "missing-claude"), queriesLiveSessions: false),
        dsh: DshSessionMonitor(sessionsRoot: fixture.root)
    )
    #expect(monitor.watchRoots.contains { $0.path == fixture.root.resolvingSymlinksInPath().path })
    #expect(await monitor.scan().map(\.id) == ["dsh:composite"])
    let newFile = try fixture.write("new-session", events: [dshEnd(seq: 0)])
    #expect(await monitor.scanChangedPaths(["/tmp/unrelated"]).map(\.id) == ["dsh:composite"])
    #expect(await monitor.scanChangedPaths([file.path]).map(\.id) == ["dsh:composite"])
    #expect(await monitor.scanChangedPaths([newFile.path]).count == 2)
    let concurrent = await withTaskGroup(of: [String].self) { group in
        for _ in 0..<20 {
            group.addTask { await monitor.scanChangedPaths([file.path, newFile.path]).map(\.id).sorted() }
        }
        var results: [[String]] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(concurrent.allSatisfy { $0 == ["dsh:composite", "dsh:new-session"] })
}

@Test
func dshChildDoesNotConsumeParentHistoryLimit() async throws {
    let fixture = try DshFixture()
    defer { fixture.remove() }
    let parent = try fixture.write("parent", events: [dshEnd(seq: 0)])
    try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: parent.path)
    try fixture.write("new-child", events: [dshEnd(seq: 0)], child: true)
    #expect(await DshSessionMonitor(sessionsRoot: fixture.root, maxFiles: 1).scan().map(\.sessionID) == ["parent"])
}

private struct DshFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "agent-inbox-dsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ id: String, events: [Data], child: Bool = false, seeded: Bool = false, version: Int = 4) throws -> URL {
        let directory = root.appending(path: "project/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header: [String: Any] = [
            "type": "session", "version": version, "id": id, "createdAt": 1_792_224_000_000,
            "cwd": "/tmp/dsh", "delegationDepth": child ? 1 : 0, "isSeeded": seeded
        ]
        var content = try JSONSerialization.data(withJSONObject: header)
        content.append(10)
        for event in events { content.append(event) }
        let file = directory.appending(path: "session.v4.jsonl")
        try content.write(to: file)
        return file
    }
}

private func dshText(_ value: String) -> [[String: String]] { [["type": "text", "text": value]] }

private func dshEvent(_ type: String, seq: Int, data: [String: Any] = [:]) -> Data {
    var line = try! JSONSerialization.data(withJSONObject: [
        "type": type, "seq": seq, "time": 1_792_224_000_000 + seq * 1_000, "data": data
    ])
    line.append(10)
    return line
}

private func dshEnd(seq: Int, reason: String = "completed") -> Data {
    dshEvent("turn/end", seq: seq, data: ["turn": 1, "reason": ["kind": reason]])
}

private func dshQuestion(seq: Int, id: String, text: String) -> Data {
    let arguments = try! JSONSerialization.data(withJSONObject: ["questions": [["id": "choice", "question": text]]])
    return dshEvent("tool/call", seq: seq, data: [
        "name": "ask_user_question", "callId": id, "arguments": String(decoding: arguments, as: UTF8.self)
    ])
}
