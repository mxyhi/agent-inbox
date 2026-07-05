import Foundation
import Testing
@testable import AgentInboxCore

// MARK: - 时间基准
// 真实 rollout 时间戳格式已于 2026-07-04 在本机验证。epoch 手工推导:
// 2026-01-01T00:00:00Z = 1767225600,2026 非闰年,7 月 4 日为第 184 天(offset 15897600)
// → 2026-07-04T00:00:00Z = 1783123200

/// "2026-07-04T14:13:01.605Z" = 1783123200 + 14*3600 + 13*60 + 1.605
private let sessionStartEpoch: TimeInterval = 1_783_174_381.605
/// "2026-07-04T14:23:29.440Z" = 1783123200 + 14*3600 + 23*60 + 29.440
private let taskCompleteEpoch: TimeInterval = 1_783_175_009.440

@Test
func monitorParsesSessionMetaAndLastTaskComplete() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 模拟真实 rollout:首行 session_meta(id/session_id 并存、cwd、带小数秒 timestamp),
    // 中间夹普通事件,尾部两个 task_complete —— 必须取最后一个
    let body = """
    {"timestamp":"2026-07-04T14:13:43.646Z","type":"session_meta","payload":{"session_id":"id-should-lose","id":"session-real","timestamp":"2026-07-04T14:13:01.605Z","cwd":"/Users/langhuam/workspace/_all_do","originator":"codex-tui","cli_version":"0.142.5"}}
    {"timestamp":"2026-07-04T14:14:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"working"}}
    {"timestamp":"2026-07-04T14:20:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"第一轮完成"}}
    {"timestamp":"2026-07-04T14:23:29.440Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2","last_agent_message":"审计完了,基于本机\\n第二行长消息"}}
    """
    let file = try writeRollout(
        root: root,
        name: "rollout-2026-07-04T14-13-01-real.jsonl",
        body: body,
        mtimeEpoch: 1_783_175_010
    )

    let monitor = CodexSessionMonitor(sessionsRoot: root)
    let summaries = await monitor.scan()

    #expect(summaries.count == 1)
    let summary = try #require(summaries.first)
    #expect(summary.id == "session-real") // payload.id 优先于 session_id
    #expect(summary.cwd == "/Users/langhuam/workspace/_all_do")
    // macOS 临时目录存在 /var ↔ /private/var 双写形式,两边统一规范化后再比对
    #expect(
        URL(filePath: summary.filePath).resolvingSymlinksInPath()
            == file.resolvingSymlinksInPath()
    )

    // startedAt 来自 session_meta.payload.timestamp,必须正确解析小数秒(旧实现的已知 bug)
    let startedAt = try #require(summary.startedAt)
    #expect(abs(startedAt.timeIntervalSince1970 - sessionStartEpoch) < 0.01)

    // taskCompletedAt 取最后一个 task_complete 的外层 timestamp
    let completedAt = try #require(summary.taskCompletedAt)
    #expect(abs(completedAt.timeIntervalSince1970 - taskCompleteEpoch) < 0.01)
    #expect(summary.lastAgentMessage == "审计完了,基于本机\n第二行长消息")
    #expect(summary.isTaskComplete)
}

@Test
func monitorExtractsFirstUserPromptSkippingInjectedContext() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 首行 session_meta;随后是注入的 role==user(AGENTS.md/环境)与 developer 上下文 —— 都应被跳过。
    // 真正的用户提示词是首个 event_msg/user_message,且 message 以空行/空白起头,需清洗为首个非空行。
    let body = """
    {"timestamp":"2026-07-04T14:13:43.646Z","type":"session_meta","payload":{"id":"session-fp","timestamp":"2026-07-04T14:13:01.605Z","cwd":"/tmp/fp"}}
    {"timestamp":"2026-07-04T14:13:44.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"text","text":"# AGENTS.md instructions <environment_context> 注入不是提示词"}]}}
    {"timestamp":"2026-07-04T14:13:45.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"text","text":"permissions instructions"}]}}
    {"timestamp":"2026-07-04T14:13:46.000Z","type":"event_msg","payload":{"type":"user_message","message":"   \\n  部署一下  \\n次要行"}}
    {"timestamp":"2026-07-04T14:20:00.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"完成"}}
    """
    _ = try writeRollout(
        root: root,
        name: "rollout-2026-07-04T14-13-01-fp.jsonl",
        body: body,
        mtimeEpoch: 1_783_175_010
    )

    let monitor = CodexSessionMonitor(sessionsRoot: root)
    let summary = try #require(await monitor.scan().first)

    // 跳过注入的 role==user,取 event_msg/user_message,并清洗为首个非空行
    #expect(summary.firstPrompt == "部署一下")
}

@Test
func monitorTruncatesOverlongFirstPrompt() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 250 字符的单行提示词(模拟终端粘贴):应截断到 200 字符 + 省略号
    let longLine = String(repeating: "长", count: 250)
    let body = """
    {"timestamp":"2026-07-04T14:13:43.646Z","type":"session_meta","payload":{"id":"session-long","timestamp":"2026-07-04T14:13:01.605Z","cwd":"/tmp/long"}}
    {"timestamp":"2026-07-04T14:13:46.000Z","type":"event_msg","payload":{"type":"user_message","message":"\(longLine)"}}
    {"timestamp":"2026-07-04T14:20:00.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"完成"}}
    """
    _ = try writeRollout(
        root: root,
        name: "rollout-2026-07-04T14-13-01-long.jsonl",
        body: body,
        mtimeEpoch: 1_783_175_010
    )

    let monitor = CodexSessionMonitor(sessionsRoot: root)
    let summary = try #require(await monitor.scan().first)

    let prompt = try #require(summary.firstPrompt)
    #expect(prompt.count == 201) // 200 字符 + 1 省略号
    #expect(prompt.hasSuffix("…"))
    #expect(prompt.hasPrefix("长长长"))
}

@Test
func monitorFallsBackToPlainISO8601WithoutFractionalSeconds() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 时间戳不带小数秒 → 走整秒兜底 formatter
    let body = """
    {"timestamp":"2026-07-04T14:13:43Z","type":"session_meta","payload":{"id":"session-plain","timestamp":"2026-07-04T14:13:01Z","cwd":"/tmp/plain"}}
    {"timestamp":"2026-07-04T14:23:29Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t","last_agent_message":"done"}}
    """
    try writeRollout(
        root: root,
        name: "rollout-2026-07-04T14-13-01-plain.jsonl",
        body: body,
        mtimeEpoch: 1_783_175_010
    )

    let summary = try #require(await CodexSessionMonitor(sessionsRoot: root).scan().first)
    let startedAt = try #require(summary.startedAt)
    #expect(abs(startedAt.timeIntervalSince1970 - 1_783_174_381) < 0.01)
    let completedAt = try #require(summary.taskCompletedAt)
    #expect(abs(completedAt.timeIntervalSince1970 - 1_783_175_009) < 0.01)
}

@Test
func monitorLeavesCompletionNilWhenNoTaskComplete() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 只有启动与中间事件,没有 task_complete → 会话仍在运行
    let body = """
    {"timestamp":"2026-07-04T17:00:00.000Z","type":"session_meta","payload":{"id":"session-live","timestamp":"2026-07-04T17:00:00.000Z","cwd":"/tmp/live"}}
    {"timestamp":"2026-07-04T17:00:05.000Z","type":"event_msg","payload":{"type":"agent_message","message":"thinking"}}
    """
    try writeRollout(
        root: root,
        name: "rollout-2026-07-04T17-00-00-live.jsonl",
        body: body,
        mtimeEpoch: 1_783_185_000
    )

    let summary = try #require(await CodexSessionMonitor(sessionsRoot: root).scan().first)
    #expect(summary.id == "session-live")
    #expect(summary.taskCompletedAt == nil)
    #expect(summary.lastAgentMessage == nil)
    #expect(!summary.isTaskComplete)
}

@Test
func monitorParsesLatestTurnLifecycleEvent() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Esc 停止后 Codex 会写 turn_aborted,随后 thread_rolled_back;最新 lifecycle 必须覆盖旧的 task_started。
    let body = """
    {"timestamp":"2026-07-04T17:10:00.000Z","type":"session_meta","payload":{"id":"session-aborted","timestamp":"2026-07-04T17:10:00.000Z","cwd":"/tmp/aborted"}}
    {"timestamp":"2026-07-04T17:10:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
    {"timestamp":"2026-07-04T17:10:05.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted","completed_at":1783185005,"duration_ms":4000}}
    {"timestamp":"2026-07-04T17:10:05.050Z","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}
    """
    try writeRollout(
        root: root,
        name: "rollout-2026-07-04T17-10-00-aborted.jsonl",
        body: body,
        mtimeEpoch: 1_783_185_005
    )

    let summary = try #require(await CodexSessionMonitor(sessionsRoot: root).scan().first)
    #expect(summary.lifecycleState == .rolledBack)
    #expect(summary.taskCompletedAt == nil)
    #expect(!summary.isTaskComplete)
}

@Test
func monitorFallsBackToFileNameWhenHeadIsNotSessionMeta() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 首行不是 session_meta → id 退化为文件名(去扩展名),cwd/startedAt 置 nil;tail 解析不受影响
    let body = """
    {"timestamp":"2026-07-04T16:00:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"legacy head"}}
    {"timestamp":"2026-07-04T16:00:01.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t","last_agent_message":"done"}}
    """
    try writeRollout(
        root: root,
        name: "rollout-2026-07-04T16-00-00-legacy.jsonl",
        body: body,
        mtimeEpoch: 1_783_181_000
    )

    let summary = try #require(await CodexSessionMonitor(sessionsRoot: root).scan().first)
    #expect(summary.id == "rollout-2026-07-04T16-00-00-legacy")
    #expect(summary.cwd == nil)
    #expect(summary.startedAt == nil)
    #expect(summary.taskCompletedAt != nil)
}

@Test
func monitorReusesCacheUntilMtimeChanges() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let name = "rollout-2026-07-04T15-00-00-cache.jsonl"
    let bodyV1 = """
    {"timestamp":"2026-07-04T15:00:00.000Z","type":"session_meta","payload":{"id":"session-cache","timestamp":"2026-07-04T15:00:00.000Z","cwd":"/tmp/cache-demo"}}
    {"timestamp":"2026-07-04T15:01:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"第一版"}}
    """
    let file = try writeRollout(root: root, name: name, body: bodyV1, mtimeEpoch: 1_783_175_000)

    let monitor = CodexSessionMonitor(sessionsRoot: root)
    let first = await monitor.scan()
    #expect(first.first?.lastAgentMessage == "第一版")

    // 内容变了但 mtime 未变 → 命中缓存,结果与上一轮完全一致(证明没有重新解析)
    let bodyV2 = bodyV1 + "\n" + """
    {"timestamp":"2026-07-04T15:02:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t2","last_agent_message":"第二版"}}
    """
    try writeRollout(root: root, name: name, body: bodyV2, mtimeEpoch: 1_783_175_000)
    let second = await monitor.scan()
    #expect(second == first)
    #expect(second.first?.lastAgentMessage == "第一版")

    // mtime 前进 → 缓存失效,重新解析出新内容
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_783_175_001)],
        ofItemAtPath: file.path
    )
    let third = await monitor.scan()
    #expect(third.first?.lastAgentMessage == "第二版")
}

@Test
func monitorIncrementallyParsesChangedRolloutOnly() async throws {
    let root = try makeTemporarySessionsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let firstFile = try writeRollout(
        root: root,
        name: "rollout-2026-07-04T18-00-00-first.jsonl",
        body: """
        {"timestamp":"2026-07-04T18:00:00.000Z","type":"session_meta","payload":{"id":"session-first","timestamp":"2026-07-04T18:00:00.000Z","cwd":"/tmp/first"}}
        {"timestamp":"2026-07-04T18:00:01.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"first-v1"}}
        """,
        mtimeEpoch: 1_783_188_001
    )
    try writeRollout(
        root: root,
        name: "rollout-2026-07-04T18-05-00-second.jsonl",
        body: """
        {"timestamp":"2026-07-04T18:05:00.000Z","type":"session_meta","payload":{"id":"session-second","timestamp":"2026-07-04T18:05:00.000Z","cwd":"/tmp/second"}}
        {"timestamp":"2026-07-04T18:05:01.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"second-v1"}}
        """,
        mtimeEpoch: 1_783_188_301
    )

    let monitor = CodexSessionMonitor(sessionsRoot: root)
    let initial = await monitor.scan()
    #expect(initial.count == 2)

    try writeRollout(
        root: root,
        name: firstFile.lastPathComponent,
        body: """
        {"timestamp":"2026-07-04T18:00:00.000Z","type":"session_meta","payload":{"id":"session-first","timestamp":"2026-07-04T18:00:00.000Z","cwd":"/tmp/first"}}
        {"timestamp":"2026-07-04T18:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t2","last_agent_message":"first-v2"}}
        """,
        mtimeEpoch: 1_783_188_500
    )

    let changed = await monitor.scanChangedPaths([firstFile.path])
    let first = try #require(changed.first { $0.id == "session-first" })
    let second = try #require(changed.first { $0.id == "session-second" })
    #expect(first.lastAgentMessage == "first-v2")
    #expect(second.lastAgentMessage == "second-v1")
}

// MARK: - fixture 辅助

/// 创建带 YYYY/MM/DD 层级的临时 sessions 根目录
private func makeTemporarySessionsRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "agent-inbox-monitor-tests")
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root.appending(path: "2026/07/04"),
        withIntermediateDirectories: true
    )
    return root
}

/// 在临时 sessions 目录写入 rollout fixture 并固定 mtime(整数秒,规避文件系统精度差异)
@discardableResult
private func writeRollout(root: URL, name: String, body: String, mtimeEpoch: TimeInterval) throws -> URL {
    let file = root.appending(path: "2026/07/04").appending(path: name)
    try body.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: mtimeEpoch)],
        ofItemAtPath: file.path
    )
    return file
}
