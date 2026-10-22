import Foundation
import Testing
@testable import AgentInboxCore

/// 0.163.0 TUI 选择框持久化为工具调用，而非 request_user_input 事件。
@Test
func codexInputRequestNotifiesAndClearsOnlyOnMatchingResult() async throws {
    let fixture = try InputRequestRollout()
    defer { fixture.remove() }
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    let resolver = AgentStatusResolver()
    let before = resolver.resolve(summaries: await monitor.scan(), completedSessionIDs: [])

    try fixture.append(InputRequestRollout.request())
    let waiting = try #require(await monitor.scan().first)
    #expect(waiting.lifecycleState == .waitingForUser)
    #expect(waiting.pendingQuestion == "是否采用当前设置？")
    let snapshot = resolver.resolve(summaries: [waiting], completedSessionIDs: [])
    #expect(snapshot.newTodos(comparedTo: before).map(\.id) == [waiting.id])
    #expect(snapshot.newTodos(comparedTo: snapshot).isEmpty)

    let restored = try #require(await CodexSessionMonitor(sessionsRoot: fixture.root).scan().first)
    #expect(restored.pendingRequestID == waiting.pendingRequestID)
    #expect(restored.lifecycleState == .waitingForUser)

    try fixture.append(InputRequestRollout.result(callID: "unrelated"))
    try fixture.append(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"补充说明"}]}}}"# + "\n")
    try fixture.append(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"> 是否采用当前设置？\n\n旧的异步回答"}]}}}"# + "\n")
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    try fixture.append(InputRequestRollout.result(callID: "ask-1"))
    let answered = try #require(await monitor.scan().first)
    #expect(answered.lifecycleState == .running)
    #expect(answered.pendingQuestion == nil)
    #expect(answered.pendingRequestID == nil)
}

@Test
func codexInputRequestReplacementAndAcknowledgementUseCallIdentity() async throws {
    let fixture = try InputRequestRollout()
    defer { fixture.remove() }
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    try fixture.append(InputRequestRollout.request())
    let first = try #require(await monitor.scan().first)
    var state = PersistedState()
    state.acknowledgeTodo(first)
    try fixture.append(InputRequestRollout.request(callID: "ask-2"))
    let second = try #require(await monitor.scan().first)
    #expect(second.pendingRequestID != first.pendingRequestID)
    #expect(AgentStatusResolver().resolve(
        summaries: [second], completedSessionIDs: [], acknowledgedRequests: state.acknowledgedRequests
    ).todos.count == 1)
    try fixture.append(InputRequestRollout.result(callID: "ask-1"))
    #expect(await monitor.scan().first?.pendingRequestID == second.pendingRequestID)
    try fixture.append(InputRequestRollout.result(callID: "ask-2"))
    #expect(await monitor.scan().first?.lifecycleState == .running)
}

@Test(arguments: ["task_complete", "turn_aborted", "thread_rolled_back"])
func codexInputRequestHandlesCompletionAndCancellation(event: String) async throws {
    let fixture = try InputRequestRollout()
    defer { fixture.remove() }
    try fixture.append(InputRequestRollout.request())
    try fixture.append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(event)\"}}\n")
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    let summary = try #require(await monitor.scan().first)
    if event == "task_complete" {
        #expect(summary.lifecycleState == .waitingForUser)
        try fixture.append(InputRequestRollout.result(callID: "ask-1"))
        #expect(await monitor.scan().first?.lifecycleState == .completed)
    } else {
        #expect(summary.lifecycleState == (event == "turn_aborted" ? .aborted : .rolledBack))
        #expect(summary.pendingRequestID == nil)
    }
}

@Test
func codexInputRequestIgnoresInvalidCallsAndEmbeddedProtocolText() async throws {
    let fixture = try InputRequestRollout()
    defer { fixture.remove() }
    let request = InputRequestRollout.request()
    let embedded = try JSONSerialization.data(withJSONObject: [
        "type": "response_item", "payload": ["type": "function_call_output", "output": request]
    ])
    try fixture.append(String(decoding: embedded, as: UTF8.self) + "\n")
    try fixture.append(request.replacingOccurrences(of: "request_user_input", with: "request_user_input_async"))
    try fixture.append(request.replacingOccurrences(of: "request_user_input", with: "exec_command"))
    try fixture.append(request.replacingOccurrences(of: "ask-1", with: ""))
    try fixture.append(request.replacingOccurrences(of: "是否采用当前设置？", with: "  "))
    try fixture.append("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"request_user_input\",\"call_id\":\"bad\",\"arguments\":\"invalid\"}}\n")
    #expect(await CodexSessionMonitor(sessionsRoot: fixture.root).scan().first?.lifecycleState == .running)
}

@Test
func codexInputRequestClearsOnErrorResult() async throws {
    let fixture = try InputRequestRollout()
    defer { fixture.remove() }
    try fixture.append(InputRequestRollout.request())
    let result = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"ask-1","output":[{"type":"input_text","text":"request_user_input is not available"}]}}"#
    try fixture.append(result + "\n")
    #expect(await CodexSessionMonitor(sessionsRoot: fixture.root).scan().first?.lifecycleState == .running)
}

@Test
func codexInputRequestPartialAppendCommitsOnlyCompleteLines() async throws {
    let fixture = try InputRequestRollout()
    defer { fixture.remove() }
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    let request = InputRequestRollout.request()
    let split = request.index(request.startIndex, offsetBy: request.count / 2)
    try fixture.append(String(request[..<split]))
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.append(String(request[split...]))
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    try fixture.append(InputRequestRollout.result(callID: "ask-1"))
    #expect(await monitor.scan().first?.lifecycleState == .running)
}

@Test
func codexPaginatedUserMessageSuppliesFirstPrompt() async throws {
    let fixture = try InputRequestRollout()
    defer { fixture.remove() }
    try fixture.append(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"AGENTS.md injected context"}]}}"# + "\n")
    try fixture.append(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"image","image_url":"data:image/png;base64,AA"}]}}}"# + "\n")
    try fixture.append(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"  \n修复通知\n补充说明"}]}}}"# + "\n")
    #expect(await CodexSessionMonitor(sessionsRoot: fixture.root).scan().first?.firstPrompt == "修复通知")
}

private struct InputRequestRollout {
    let root: URL
    let file: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        file = root.appending(path: "rollout-input.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        {"type":"session_meta","payload":{"id":"input-request","cwd":"/tmp/input-request","cli_version":"0.163.0"}}
        {"type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: file)
    }

    static func request(callID: String = "ask-1") -> String {
        #"""
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"设置\",\"id\":\"settings\",\"question\":\"是否采用当前设置？\",\"options\":[{\"label\":\"采用\",\"description\":\"保留当前参数\"}]}]}","call_id":"\#(callID)"}}

        """#
    }

    static func result(callID: String) -> String {
        #"""
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"\#(callID)","output":"{\"answers\":{\"settings\":{\"answers\":[\"采用\"]}}}"}}

        """#
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
