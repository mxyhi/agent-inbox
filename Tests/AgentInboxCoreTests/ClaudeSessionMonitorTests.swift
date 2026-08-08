import Foundation
import Testing
@testable import AgentInboxCore

@Test
func claudeMonitorParsesCompletedTranscriptAndSkipsSyntheticTitle() async throws {
    let root = try makeTemporaryClaudeProjectsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let transcript = #"""
    {"type":"queue-operation","sessionId":"claude-completed","timestamp":"2026-08-08T10:00:00.000Z"}
    {"type":"user","sessionId":"claude-completed","timestamp":"2026-08-08T10:00:00.100Z","cwd":"/tmp/claude-project","message":{"role":"user","content":"Generate a concise tab title for this chat.\nReturn only title."}}
    {"type":"user","sessionId":"claude-completed","timestamp":"2026-08-08T10:00:01.000Z","cwd":"/tmp/claude-project","message":{"role":"user","content":"  \n支持 Claude Code\n次要行"}}
    {"type":"assistant","sessionId":"claude-completed","timestamp":"2026-08-08T10:00:03.000Z","cwd":"/tmp/claude-project","message":{"role":"assistant","content":[{"type":"thinking","thinking":"reasoning"}]}}
    {"type":"assistant","sessionId":"claude-completed","timestamp":"2026-08-08T10:00:04.000Z","cwd":"/tmp/claude-project","message":{"role":"assistant","content":[{"type":"text","text":"实现完成\n已运行测试"}]}}
    {"type":"system","subtype":"stop_hook_summary","sessionId":"claude-completed","timestamp":"2026-08-08T10:00:04.100Z"}
    {"type":"system","subtype":"turn_duration","sessionId":"claude-completed","timestamp":"2026-08-08T10:00:04.200Z"}
    """#
    let file = try writeClaudeTranscript(
        root: root,
        project: "-tmp-claude-project",
        name: "claude-completed.jsonl",
        body: transcript,
        modifiedAt: Date(timeIntervalSince1970: 1_786_151_000)
    )

    let monitor = ClaudeSessionMonitor(sessionsRoot: root, queriesLiveSessions: false)
    let summary = try #require(await monitor.scan().first)

    #expect(summary.provider == .claude)
    #expect(summary.sessionID == "claude-completed")
    #expect(summary.id == "claude:claude-completed")
    #expect(summary.cwd == "/tmp/claude-project")
    #expect(summary.firstPrompt == "支持 Claude Code")
    #expect(summary.lastAgentMessage == "实现完成\n已运行测试")
    #expect(summary.lifecycleState == .completed)
    #expect(summary.taskCompletedAt != nil)
    #expect(
        URL(filePath: summary.filePath).resolvingSymlinksInPath()
            == file.resolvingSymlinksInPath()
    )
}

@Test
func claudeMonitorMarksUnfinishedTranscriptRunning() async throws {
    let root = try makeTemporaryClaudeProjectsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 最近 turn 尚未写出 stop 标记时，assistant tool_use 仍表示正在工作。
    let transcript = """
    {"type":"user","sessionId":"claude-running","timestamp":"2026-08-08T10:00:00.000Z","cwd":"/tmp/running","message":{"role":"user","content":"继续执行"}}
    {"type":"assistant","sessionId":"claude-running","timestamp":"2026-08-08T10:00:01.000Z","cwd":"/tmp/running","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
    """
    _ = try writeClaudeTranscript(
        root: root,
        project: "-tmp-running",
        name: "claude-running.jsonl",
        body: transcript,
        modifiedAt: Date()
    )

    let monitor = ClaudeSessionMonitor(sessionsRoot: root, queriesLiveSessions: false)
    let summary = try #require(await monitor.scan().first)

    #expect(summary.lifecycleState == .running)
    #expect(summary.taskCompletedAt == nil)
    #expect(summary.firstPrompt == "继续执行")
}

@Test
func claudeMonitorIgnoresNestedSubagentTranscript() async throws {
    let root = try makeTemporaryClaudeProjectsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let mainTranscript = """
    {"type":"user","sessionId":"claude-main","timestamp":"2026-08-08T10:00:00.000Z","cwd":"/tmp/main","message":{"role":"user","content":"主会话"}}
    {"type":"system","subtype":"turn_duration","sessionId":"claude-main","timestamp":"2026-08-08T10:00:01.000Z"}
    """
    _ = try writeClaudeTranscript(
        root: root,
        project: "-tmp-main",
        name: "claude-main.jsonl",
        body: mainTranscript,
        modifiedAt: Date()
    )

    let nestedDirectory = root
        .appending(path: "-tmp-main/claude-main/subagents")
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try Data(mainTranscript.utf8).write(to: nestedDirectory.appending(path: "claude-subagent.jsonl"))

    let monitor = ClaudeSessionMonitor(sessionsRoot: root, queriesLiveSessions: false)
    let summaries = await monitor.scan()

    #expect(summaries.map(\.sessionID) == ["claude-main"])
}

@Test
func claudeMonitorUsesLiveCLIStatusOverTranscriptFallback() async throws {
    let root = try makeTemporaryClaudeProjectsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let completedTranscript = """
    {"type":"user","sessionId":"claude-active","timestamp":"2026-08-08T10:00:00.000Z","cwd":"/tmp/active","message":{"role":"user","content":"旧一轮"}}
    {"type":"system","subtype":"turn_duration","sessionId":"claude-active","timestamp":"2026-08-08T10:00:01.000Z"}
    """
    _ = try writeClaudeTranscript(
        root: root,
        project: "-tmp-active",
        name: "claude-active.jsonl",
        body: completedTranscript,
        modifiedAt: Date()
    )

    let unfinishedTranscript = """
    {"type":"user","sessionId":"claude-idle","timestamp":"2026-08-08T10:00:00.000Z","cwd":"/tmp/idle","message":{"role":"user","content":"已停住"}}
    """
    _ = try writeClaudeTranscript(
        root: root,
        project: "-tmp-idle",
        name: "claude-idle.jsonl",
        body: unfinishedTranscript,
        modifiedAt: Date()
    )

    // 假 CLI 固定返回一条 active 与一条 idle，隔离本机真实 Claude 会话。
    let executable = root.appending(path: "fake-claude")
    let script = #"""
    #!/bin/sh
    printf '%s\n' '[{"sessionId":"claude-active","status":"active"},{"sessionId":"claude-idle","status":"idle"}]'
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let monitor = ClaudeSessionMonitor(
        sessionsRoot: root,
        claudeExecutableURL: executable
    )
    let summaries = Dictionary(uniqueKeysWithValues: await monitor.scan().map { ($0.sessionID, $0) })

    #expect(summaries["claude-active"]?.lifecycleState == .running)
    #expect(summaries["claude-active"]?.taskCompletedAt == nil)
    #expect(summaries["claude-idle"]?.lifecycleState == .completed)
    #expect(summaries["claude-idle"]?.taskCompletedAt != nil)
}

@Test
func compositeMonitorMergesClaudeAndPublishesItsWatchRoot() async throws {
    let temporaryRoot = try makeTemporaryClaudeProjectsRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let codexRoot = temporaryRoot.appending(path: "codex")
    let grokRoot = temporaryRoot.appending(path: "grok")
    let claudeRoot = temporaryRoot.appending(path: "claude")
    try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: grokRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)

    let transcript = """
    {"type":"user","sessionId":"claude-composite","timestamp":"2026-08-08T10:00:00.000Z","cwd":"/tmp/composite","message":{"role":"user","content":"组合扫描"}}
    {"type":"system","subtype":"turn_duration","sessionId":"claude-composite","timestamp":"2026-08-08T10:00:01.000Z"}
    """
    _ = try writeClaudeTranscript(
        root: claudeRoot,
        project: "-tmp-composite",
        name: "claude-composite.jsonl",
        body: transcript,
        modifiedAt: Date()
    )

    let claude = ClaudeSessionMonitor(sessionsRoot: claudeRoot, queriesLiveSessions: false)
    let composite = CompositeSessionMonitor(
        codex: CodexSessionMonitor(sessionsRoot: codexRoot),
        grok: GrokSessionMonitor(
            sessionsRoot: grokRoot,
            activeSessionsFile: temporaryRoot.appending(path: "active_sessions.json")
        ),
        claude: claude
    )
    let summaries = await composite.scan()

    #expect(summaries.map(\.id) == ["claude:claude-composite"])
    #expect(composite.watchRoots.contains(claudeRoot))
}

private func makeTemporaryClaudeProjectsRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "agent-inbox-claude-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@discardableResult
private func writeClaudeTranscript(
    root: URL,
    project: String,
    name: String,
    body: String,
    modifiedAt: Date
) throws -> URL {
    let directory = root.appending(path: project)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: name)
    try Data(body.utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
    return file
}
