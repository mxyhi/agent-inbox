import Foundation
import Testing
@testable import AgentInboxCore

/// 复现真实模式：提问后继续输出大量工具记录，十分钟后仍需用户处理。
@Test(arguments: [false, true])
func questionSurvivesLogGrowthAndRestart(incremental: Bool) async throws {
    let fixture = try QuestionRollout()
    defer { fixture.remove() }
    try fixture.append(QuestionRollout.question)
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    if incremental {
        #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    }
    try fixture.append(QuestionRollout.largeOutput)
    let summaries = incremental
        ? await monitor.scanChangedPaths([fixture.file.path])
        : await monitor.scan()
    #expect(summaries.count == 1, "缓存路径：\(summaries.map(\.filePath))")
    let snapshot = AgentStatusResolver().resolve(
        summaries: summaries,
        completedSessionIDs: [],
        now: Date().addingTimeInterval(601)
    )
    #expect(snapshot.todos.count == 1)
    #expect(snapshot.todos.first?.pendingQuestion == "继续吗？")

    // 冷启动与已有缓存的解析结果必须一致，后续完成也不能吞掉问题。
    try fixture.append(QuestionRollout.completion)
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    #expect(await CodexSessionMonitor(sessionsRoot: fixture.root).scan().first?.lifecycleState == .waitingForUser)

    try fixture.append(QuestionRollout.answer)
    let answered = try #require(await monitor.scanChangedPaths([fixture.file.path]).first)
    #expect(answered.lifecycleState == .completed)
    #expect(answered.lastAgentMessage == "完成")
    #expect(answered.pendingQuestion == nil)
    #expect(await CodexSessionMonitor(sessionsRoot: fixture.root).scan().first?.lifecycleState == .completed)
}

/// 重复收到某题回答只消费该题，剩余问题必须继续作为待办展示。
@Test
func duplicateAnswerDoesNotDismissAnotherQuestion() async throws {
    let fixture = try QuestionRollout()
    defer { fixture.remove() }
    try fixture.append(QuestionRollout.question)
    try fixture.append(QuestionRollout.question.replacingOccurrences(of: "继续吗？", with: "第二个问题"))
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    #expect(await monitor.scan().first?.pendingQuestion == "继续吗？")
    try fixture.append(QuestionRollout.answer + QuestionRollout.answer)
    let summary = try #require(await monitor.scanChangedPaths([fixture.file.path]).first)
    #expect(summary.lifecycleState == .waitingForUser)
    #expect(summary.pendingQuestion == "第二个问题")
}

/// 中断或回滚会结束当前待处理请求，全历史恢复不能复活已取消的问题。
@Test(arguments: ["turn_aborted", "thread_rolled_back"])
func cancelledTurnDiscardsPendingQuestion(event: String) async throws {
    let fixture = try QuestionRollout()
    defer { fixture.remove() }
    try fixture.append(QuestionRollout.question)
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    try fixture.append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(event)\"}}\n")
    let summaries = await monitor.scan()
    let snapshot = AgentStatusResolver().resolve(summaries: summaries, completedSessionIDs: [])
    #expect(snapshot.todos.isEmpty)
    #expect(summaries.first?.pendingQuestion == nil)
}

/// 文件可能在 UTF-8 字符或 JSON 中间暂时结束；补齐时不能丢失或重复问题。
@Test
func questionRecoversFromPartialUTF8AndAnswerWrites() async throws {
    let fixture = try QuestionRollout()
    defer { fixture.remove() }
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    let question = Data(QuestionRollout.question.utf8)
    let split = try #require(question.range(of: Data("继续".utf8))).lowerBound + 1
    try fixture.appendBytes(question.prefix(split))
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.appendBytes(question.suffix(from: split))
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)

    // 完整 JSON 暂时没有换行时也可展示，随后追加换行与回答只归并一次。
    let answer = Data(QuestionRollout.answer.utf8)
    try fixture.appendBytes(answer.dropLast(4))
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    try fixture.appendBytes(answer.suffix(4).dropLast())
    #expect(await monitor.scan().first?.lifecycleState == .running)
    try fixture.append("\n" + QuestionRollout.completion)
    #expect(await monitor.scan().first?.lifecycleState == .completed)
}

/// 原子替换和原地截断不能继承旧文件的未回答问题或读取偏移。
@Test(arguments: [false, true])
func questionStateResetsWhenLogIsReplaced(atomic: Bool) async throws {
    let fixture = try QuestionRollout()
    defer { fixture.remove() }
    try fixture.append(QuestionRollout.question)
    let monitor = CodexSessionMonitor(sessionsRoot: fixture.root)
    #expect(await monitor.scan().first?.lifecycleState == .waitingForUser)
    let replacement = QuestionRollout.header + (atomic ? QuestionRollout.largeOutput : "") + QuestionRollout.completion
    if atomic {
        try Data(replacement.utf8).write(to: fixture.file, options: .atomic)
    } else {
        let handle = try FileHandle(forWritingTo: fixture.file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
    }
    let result = try #require(await monitor.scanChangedPaths([fixture.file.path]).first)
    #expect(result.lifecycleState == .completed)
    #expect(result.lastAgentMessage == "完成")
}

/// 合成记录不含真实对话；使用真实追加写法覆盖缓存路径。
private struct QuestionRollout {
    let root: URL
    let file: URL
    static let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"question-recovery\",\"cwd\":\"/tmp/question-recovery\"}}\n"
    static let question = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"AgentMessage\",\"delivery\":\"async\",\"questions\":[{\"title\":\"继续吗？\"}]}}}\n"
    static let answer = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"UserMessage\",\"content\":[{\"type\":\"text\",\"text\":\"> 继续吗？\\n\\n继续\"}]}}}\n"
    static let completion = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"完成\"}}\n"
    static let largeOutput = String(repeating: "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"" + String(repeating: "工具输出", count: 100) + "\"}}\n", count: 2048)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        file = root.appending(path: "rollout-question.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.header.utf8).write(to: file)
    }

    func append(_ text: String) throws {
        try appendBytes(Data(text.utf8))
    }

    func appendBytes(_ bytes: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
