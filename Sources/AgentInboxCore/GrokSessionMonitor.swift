import Darwin
import Foundation
import OSLog

/// Grok 主回合与后台工作监控。进程归属取实际打开的会话文件，状态来自增量事件。
/// 后台命令、monitor、有效 loop、子代理跨回合继续运行；子会话只汇总到父对话。
public actor GrokSessionMonitor {
    private struct CachedEntry {
        let summary: SessionSummary
    }

    private struct SummaryFile: Decodable {
        struct Info: Decodable {
            let id: String?
            let cwd: String?
        }

        let info: Info?
        let sessionSummary: String?
        let generatedTitle: String?
        let createdAt: String?
        let updatedAt: String?
        let lastActiveAt: String?
        let numMessages: Int?
        let numChatMessages: Int?

        enum CodingKeys: String, CodingKey {
            case info
            case sessionSummary = "session_summary"
            case generatedTitle = "generated_title"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case lastActiveAt = "last_active_at"
            case numMessages = "num_messages"
            case numChatMessages = "num_chat_messages"
        }
    }

    private struct ActiveSessionRecord: Decodable {
        let pid: Int32
    }

    private struct UpdatesEnvelope: Decodable {
        let params: Params?

        struct Params: Decodable {
            let update: Update?
        }

        struct Update: Decodable {
            let sessionUpdate: String?
            let content: Content?

            enum CodingKeys: String, CodingKey {
                case sessionUpdate
                case content
            }
        }

        struct Content: Decodable {
            let type: String?
            let text: String?
        }
    }

    public nonisolated let sessionsRoot: URL
    public nonisolated let activeSessionsFile: URL
    private let maxFiles: Int
    private let updatesByteLimit: Int
    private let inspectProcess: @Sendable (Int32) -> GrokProcessSnapshot?
    private var runtime: [String: GrokRuntimeState] = [:]
    private var promptCache: [String: (stamp: GrokFileStamp, first: String?, last: String?)] = [:]
    private var liveSessions: [String: GrokProcessSnapshot] = [:]
    private var inspectionFailures: Set<Int32> = []
    private let logger = Logger(subsystem: "agent-inbox", category: "GrokSessionMonitor")

    private let fractionalFormatter: ISO8601DateFormatter
    private let plainFormatter: ISO8601DateFormatter

    /// key = session 目录 path
    private var cache: [String: CachedEntry] = [:]
    /// 已经确认属于父对话的子会话 id。新待办替换的是父对话那一条。
    private var subagentIDs: Set<String> = []
    private var lastLoggedSkippedSubagentCount = 0

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".grok/sessions"),
        activeSessionsFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".grok/active_sessions.json"),
        maxFiles: Int = 80,
        updatesByteLimit: Int = 256 * 1024
    ) {
        self.init(sessionsRoot: sessionsRoot, activeSessionsFile: activeSessionsFile,
                  maxFiles: maxFiles, updatesByteLimit: updatesByteLimit,
                  inspectProcess: { GrokProcessSnapshot.read(pid: $0) })
    }

    init(sessionsRoot: URL, activeSessionsFile: URL, maxFiles: Int = 80,
         updatesByteLimit: Int = 256 * 1024,
         inspectProcess: @escaping @Sendable (Int32) -> GrokProcessSnapshot?) {
        self.inspectProcess = inspectProcess
        self.sessionsRoot = sessionsRoot.resolvingSymlinksInPath()
        self.activeSessionsFile = activeSessionsFile.resolvingSymlinksInPath()
        self.maxFiles = maxFiles
        self.updatesByteLimit = updatesByteLimit

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalFormatter = fractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plainFormatter = plain
    }

    /// 全量扫描最近 session 目录
    public func scan() -> [SessionSummary] {
        // Swift actor 工作线程没有每轮 AppKit run loop 的 autorelease pool。
        // 大目录枚举产生的 Foundation 临时对象必须在本轮结束释放。
        autoreleasepool { scanSessions() }
    }

    private func scanSessions() -> [SessionSummary] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            cache.removeAll()
            runtime.removeAll()
            promptCache.removeAll()
            logger.info("Grok sessions root missing: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        refreshLiveSessions(fileManager: fileManager)
        let dirs = recentSessionDirectories(fileManager: fileManager)
        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(dirs.count)

        for dir in dirs {
            let path = dir.url.path
            do {
                let summary = try autoreleasepool { try parseSessionDirectory(
                    at: dir.url,
                    sessionID: dir.sessionID,
                    summaryModifiedAt: dir.summaryModifiedAt,
                    eventsModifiedAt: dir.eventsModifiedAt,
                    host: liveSessions[path]
                ) }
                cache[path] = CachedEntry(summary: summary)
                summaries.append(summary)
            } catch {
                cache.removeValue(forKey: path)
                logger.error(
                    "Failed to parse Grok session \(path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        let alivePaths = Set(dirs.map(\.url.path))
        cache = cache.filter { alivePaths.contains($0.key) }
        runtime = runtime.filter { alivePaths.contains($0.key) }
        promptCache = promptCache.filter { alivePaths.contains($0.key) }

        logger.debug(
            "Scanned \(dirs.count, privacy: .public) Grok sessions, attached \(self.liveSessions.count, privacy: .public)"
        )
        return summaries
    }

    /// 增量扫描:命中 session 目录或 active_sessions 时局部刷新;目录级事件回退 full scan
    public func scanChangedPaths(_ changedPaths: [String]) -> [SessionSummary] {
        autoreleasepool { scanChangedSessions(changedPaths) }
    }

    private func scanChangedSessions(_ changedPaths: [String]) -> [SessionSummary] {
        guard !changedPaths.isEmpty else {
            return cachedSummaries()
        }
        guard !cache.isEmpty else {
            logger.debug("Grok incremental scan before cache warm-up; full scan")
            return scan()
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            cache.removeAll()
            runtime.removeAll()
            promptCache.removeAll()
            logger.info("Grok sessions root missing during incremental scan")
            return []
        }

        var requiresFullScan = false
        var sessionDirs = Set<String>()
        let sessionsRootPath = sessionsRoot.standardizedFileURL.path
        let activePath = activeSessionsFile.standardizedFileURL.path

        for path in changedPaths {
            let url = URL(filePath: path).resolvingSymlinksInPath()
            let pathString = url.path

            // active_sessions 变化影响全部 alive 位 → 全扫
            if pathString == activePath || url.lastPathComponent == "active_sessions.json" {
                requiresFullScan = true
                break
            }

            // 忽略 sessions 树以外的 ~/.grok 噪声(memtrace/logs 等)
            guard pathString == sessionsRootPath || pathString.hasPrefix(sessionsRootPath + "/") else {
                continue
            }

            if let childID = subagentID(in: url) {
                noteSubagent(childID)
            }
            if let sessionDir = sessionDirectory(containing: url) {
                sessionDirs.insert(sessionDir.path)
            } else if isLikelyDirectoryEvent(url, fileManager: fileManager) {
                requiresFullScan = true
                break
            }
        }

        if requiresFullScan {
            logger.debug("Grok directory-level or active_sessions change; full scan")
            return scan()
        }
        guard !sessionDirs.isEmpty else {
            return cachedSummaries()
        }

        refreshLiveSessions(fileManager: fileManager)
        var reparsed = 0
        // 子代理变化要重新归并父会话；同时复核活宿主，避免退出/切换后保留旧快照。
        sessionDirs.formUnion(liveSessions.keys)
        sessionDirs.formUnion(cache.filter { $0.value.summary.runtimeVerified == true }.map(\.key))
        for path in sessionDirs {
            if updateCachedSession(at: URL(filePath: path), fileManager: fileManager) {
                reparsed += 1
            }
        }
        trimCacheToMaxFiles()

        logger.debug(
            "Grok incrementally scanned \(sessionDirs.count, privacy: .public) dirs, reparsed \(reparsed, privacy: .public)"
        )
        return cachedSummaries()
    }

    // MARK: - 枚举

    private struct SessionDirInfo {
        let url: URL
        let sessionID: String
        let summaryModifiedAt: Date
        let eventsModifiedAt: Date?
    }

    /// 枚举 sessionsRoot 下全部 summary.json,按 mtime 取最近 maxFiles
    private func recentSessionDirectories(fileManager: FileManager) -> [SessionDirInfo] {
        // 找到会话根就停止向下递归；checkpoints、终端输出等历史树不参与会话发现。
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var dirs: [SessionDirInfo] = []
        var seenSubagents = subagentIDs
        for case let directory as URL in enumerator {
            autoreleasepool {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
                let summaryURL = directory.appending(path: "summary.json")
                guard let values = try? summaryURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let summaryMtime = values.contentModificationDate else { return }
                enumerator.skipDescendants()
                let sessionDir = directory.resolvingSymlinksInPath()
                let children = (try? fileManager.contentsOfDirectory(
                    atPath: sessionDir.appending(path: "subagents").path
                )) ?? []
                seenSubagents.formUnion(children)
                let eventsMtime = try? sessionDir.appending(path: "events.jsonl")
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                dirs.append(SessionDirInfo(url: sessionDir, sessionID: sessionDir.lastPathComponent,
                    summaryModifiedAt: summaryMtime, eventsModifiedAt: eventsMtime))
            }
        }

        // 先丢掉子会话再截断。否则 80 个新子会话会把父对话挤出窗口，列表里只剩重复待办。
        let conversations = dirs.filter { dir in
            if seenSubagents.contains(dir.sessionID) || isSubagentAudience(at: dir.url) {
                seenSubagents.insert(dir.sessionID)
                return false
            }
            return true
        }
        let skipped = dirs.count - conversations.count
        if skipped > 0, skipped != lastLoggedSkippedSubagentCount {
            logger.info("子会话不单独进入待办: skipped=\(skipped, privacy: .public)")
            lastLoggedSkippedSubagentCount = skipped
        }
        subagentIDs = seenSubagents

        // 按 summary/events 较新者排序
        let ordered = conversations.sorted { lhs, rhs in
                let left = max(lhs.summaryModifiedAt, lhs.eventsModifiedAt ?? .distantPast)
                let right = max(rhs.summaryModifiedAt, rhs.eventsModifiedAt ?? .distantPast)
                return left > right
            }
        // 历史窗口不能挤掉静默但仍在运行的会话。
        return ordered.filter { liveSessions[$0.url.path] != nil }
            + ordered.filter { liveSessions[$0.url.path] == nil }.prefix(maxFiles)
    }

    /// `.../subagents/<session-id>/...` 的下一段就是子会话 id。
    private func subagentID(in url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.lastIndex(of: "subagents") else { return nil }
        let childIndex = parts.index(after: index)
        guard childIndex < parts.endIndex else { return nil }
        let child = parts[childIndex]
        guard !child.isEmpty, child != "summary.json" else { return nil }
        return child
    }

    /// 文件头的 audience。子会话结果回到父对话，不占第二条待办。
    private func isSubagentAudience(at sessionDir: URL) -> Bool {
        let url = sessionDir.appending(path: "prompt_context.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 512),
              let text = String(data: prefix, encoding: .utf8) else { return false }
        return text.contains("\"audience\": \"subagent\"") || text.contains("\"audience\":\"subagent\"")
    }

    private func noteSubagent(_ sessionID: String) {
        subagentIDs.insert(sessionID)
        let removed = cache.filter { $0.value.summary.sessionID == sessionID }.map(\.key)
        for path in removed {
            cache.removeValue(forKey: path)
            runtime.removeValue(forKey: path)
            promptCache.removeValue(forKey: path)
            logger.info("子会话移出待办: \(sessionID, privacy: .public)")
        }
    }

    // MARK: - 活宿主与会话归属

    private func refreshLiveSessions(fileManager: FileManager) {
        liveSessions.removeAll()
        guard fileManager.fileExists(atPath: activeSessionsFile.path) else { return }
        do {
            let records = try JSONDecoder().decode([ActiveSessionRecord].self, from: Data(contentsOf: activeSessionsFile))
            let root = sessionsRoot.standardizedFileURL.path + "/"
            for pid in Set(records.map(\.pid)) where pid > 0 {
                guard let inspected = inspectProcess(pid) else {
                    if inspectionFailures.insert(pid).inserted {
                        logger.info("Grok 宿主未确认或已退出: pid=\(pid, privacy: .public)")
                    }
                    continue
                }
                let host = GrokProcessSnapshot(startedAt: inspected.startedAt,
                    openFiles: Set(inspected.openFiles.map { URL(filePath: $0).resolvingSymlinksInPath().path }))
                inspectionFailures.remove(pid)
                for path in host.openFiles where path.hasPrefix(root) && path.hasSuffix("/events.jsonl") {
                    let sessionPath = URL(filePath: path).deletingLastPathComponent().path
                    // 一个宿主可承载多个会话；关闭对应事件文件即撤销归属。
                    if let previous = liveSessions[sessionPath] {
                        liveSessions[sessionPath] = GrokProcessSnapshot(startedAt: min(previous.startedAt, host.startedAt), openFiles: previous.openFiles.union(host.openFiles))
                    } else { liveSessions[sessionPath] = host }
                }
            }
        } catch {
            logger.error("读取 Grok 活动登记失败: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 解析

    private func parseSessionDirectory(
        at sessionDir: URL,
        sessionID: String,
        summaryModifiedAt: Date,
        eventsModifiedAt: Date?,
        host: GrokProcessSnapshot?
    ) throws -> SessionSummary {
        let summaryURL = sessionDir.appending(path: "summary.json")
        let summaryData = try Data(contentsOf: summaryURL)
        let summaryFile = try JSONDecoder().decode(SummaryFile.self, from: summaryData)

        let resolvedSessionID = summaryFile.info?.id ?? sessionID
        let cwd = summaryFile.info?.cwd
        let startedAt = summaryFile.createdAt.flatMap { parseISO8601($0) }
        let lastActive = summaryFile.lastActiveAt.flatMap { parseISO8601($0) }
            ?? summaryFile.updatedAt.flatMap { parseISO8601($0) }
        let state = runtime[sessionDir.path] ?? GrokRuntimeState()
        runtime[sessionDir.path] = state
        try state.refresh(at: sessionDir)
        let backgroundCount = try host.map { try state.backgroundCount(at: sessionDir, host: $0, now: Date()) } ?? 0
        // 宿主退出/重启后不能把残留后台任务静默当作「已完成」。保留未知，等待真实结束证据。
        let unresolvedBackground = try backgroundCount == 0
            && (state.backgroundCount(at: sessionDir,
                host: GrokProcessSnapshot(startedAt: .distantPast, openFiles: []), now: Date())) > 0
        let request = host.flatMap { state.pendingRequest(host: $0) }
        let eventsMtime = eventsModifiedAt ?? summaryModifiedAt
        let modifiedAt = max(summaryModifiedAt, eventsMtime, lastActive ?? .distantPast)

        let lifecycle: TurnLifecycleState
        let taskCompletedAt: Date?

        if request != nil {
            lifecycle = .waitingForUser
            taskCompletedAt = nil
        } else if backgroundCount > 0 {
            lifecycle = .running
            taskCompletedAt = nil
        } else if unresolvedBackground {
            lifecycle = .unknown
            taskCompletedAt = nil
        } else {
            switch state.turn {
            case let .started(at):
                lifecycle = host.map { (at ?? .distantPast) >= $0.startedAt } == true ? .running : .unknown
                taskCompletedAt = nil
            case let .ended(at, outcome):
                lifecycle = outcome == nil || outcome == "completed" ? .completed : .aborted
                taskCompletedAt = lifecycle == .completed
                    ? max(at ?? lastActive ?? modifiedAt, state.lastWorkEndedAt ?? .distantPast) : nil
            case .none:
                lifecycle = .unknown
                taskCompletedAt = nil
            }
        }

        // 文案:有展示价值时再读 updates;否则用 title fallback,避免大文件 IO
        let needsCopy = lifecycle == .running || lifecycle == .completed
        let prompts: (first: String?, last: String?)
        if needsCopy {
            prompts = parsePrompts(updatesURL: sessionDir.appending(path: "updates.jsonl"))
        } else {
            prompts = (nil, nil)
        }

        let titleFallback = nonEmpty(
            summaryFile.generatedTitle
        ) ?? nonEmpty(summaryFile.sessionSummary)

        let firstPrompt = prompts.first ?? titleFallback
        let lastAgentMessage = prompts.last ?? (lifecycle == .completed ? titleFallback : nil)

        // 无用户意图的空会话不进 completed 语义(resolver 仍可滤,这里直接降为 unknown)
        let finalLifecycle: TurnLifecycleState
        if lifecycle == .completed, firstPrompt == nil, (summaryFile.numChatMessages ?? 0) < 2 {
            finalLifecycle = .unknown
        } else {
            finalLifecycle = lifecycle
        }

        logger.debug(
            "Parsed Grok session \(resolvedSessionID, privacy: .public): lifecycle=\(finalLifecycle.rawValue, privacy: .public), alive=\(host != nil, privacy: .public), background=\(backgroundCount, privacy: .public)"
        )

        return SessionSummary(
            provider: .grok,
            sessionID: resolvedSessionID,
            filePath: sessionDir.path,
            cwd: cwd,
            startedAt: startedAt,
            modifiedAt: modifiedAt,
            lifecycleState: finalLifecycle,
            taskCompletedAt: finalLifecycle == .completed ? taskCompletedAt : nil,
            lastAgentMessage: lastAgentMessage,
            firstPrompt: firstPrompt,
            pendingQuestion: request?.question,
            pendingRequestID: request?.id,
            runtimeVerified: host != nil,
            backgroundTaskCount: backgroundCount
        )
    }

    /// 限额扫描 updates.jsonl:首个 user_message_chunk + 最近一轮 agent_message_chunk
    private func parsePrompts(updatesURL: URL) -> (first: String?, last: String?) {
        let path = updatesURL.deletingLastPathComponent().path
        guard let stamp = GrokFileStamp(updatesURL) else {
            promptCache.removeValue(forKey: path)
            return (nil, nil)
        }
        if let cached = promptCache[path], cached.stamp == stamp {
            return (cached.first, cached.last)
        }

        do {
            let handle = try FileHandle(forReadingFrom: updatesURL)
            defer { try? handle.close() }

            // head:找 first user prompt
            let headData = try handle.read(upToCount: updatesByteLimit) ?? Data()
            let firstPrompt = extractFirstUserPrompt(from: headData)

            // tail:拼最近 agent_message_chunk
            guard let size = try? handle.seekToEnd() else {
                return (firstPrompt, nil)
            }
            let offset = size > UInt64(updatesByteLimit) ? size - UInt64(updatesByteLimit) : 0
            guard (try? handle.seek(toOffset: offset)) != nil,
                  var tailData = try? handle.readToEnd() else {
                return (firstPrompt, nil)
            }
            if offset > 0 {
                if let firstNewline = tailData.firstIndex(of: UInt8(ascii: "\n")) {
                    tailData = Data(tailData.suffix(from: firstNewline + 1))
                } else {
                    tailData = Data()
                }
            }
            let lastAgent = extractLastAgentMessage(from: tailData)
            promptCache[path] = (stamp, firstPrompt, lastAgent)
            return (firstPrompt, lastAgent)
        } catch {
            logger.error(
                "Failed to read updates.jsonl \(updatesURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return (nil, nil)
        }
    }

    private func extractFirstUserPrompt(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        var chunks: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("user_message_chunk") else { continue }
            guard let envelope = try? decoder.decode(UpdatesEnvelope.self, from: Data(line.utf8)),
                  envelope.params?.update?.sessionUpdate == "user_message_chunk",
                  let piece = envelope.params?.update?.content?.text,
                  !piece.isEmpty else {
                continue
            }
            chunks.append(piece)
            // 用户首条 prompt 通常很短;凑够一段就停
            let joined = chunks.joined()
            if joined.contains("\n") || joined.count > 20 {
                break
            }
        }

        guard !chunks.isEmpty else { return nil }
        return sanitizePrompt(chunks.joined())
    }

    private func extractLastAgentMessage(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        var lastChunks: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("agent_message_chunk") || line.contains("user_message_chunk") else {
                continue
            }
            guard let envelope = try? decoder.decode(UpdatesEnvelope.self, from: Data(line.utf8)),
                  let kind = envelope.params?.update?.sessionUpdate else {
                continue
            }
            // 新的 user 消息开启新一轮,清空 agent 缓冲
            if kind == "user_message_chunk" {
                lastChunks = []
                continue
            }
            guard kind == "agent_message_chunk",
                  let piece = envelope.params?.update?.content?.text else {
                continue
            }
            lastChunks.append(piece)
        }

        guard !lastChunks.isEmpty else { return nil }
        return sanitizePrompt(lastChunks.joined())
    }

    private static let promptMaxLength = 200

    private func sanitizePrompt(_ message: String) -> String? {
        let cleaned = message
            .replacingOccurrences(of: "<user_query>", with: "")
            .replacingOccurrences(of: "</user_query>", with: "")
        let firstNonEmptyLine = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let line = firstNonEmptyLine else { return nil }
        guard line.count > Self.promptMaxLength else { return line }
        return "\(line.prefix(Self.promptMaxLength))…"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 缓存维护

    private func updateCachedSession(
        at sessionDir: URL,
        fileManager: FileManager
    ) -> Bool {
        let path = sessionDir.path
        let summaryURL = sessionDir.appending(path: "summary.json")
        guard fileManager.fileExists(atPath: summaryURL.path) else {
            cache.removeValue(forKey: path)
            return false
        }

        do {
            let summaryValues = try summaryURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let summaryMtime = summaryValues.contentModificationDate else {
                cache.removeValue(forKey: path)
                return false
            }
            let eventsURL = sessionDir.appending(path: "events.jsonl")
            let eventsMtime = try? eventsURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let sessionID = sessionDir.lastPathComponent
            // 父对话的子会话即使写成同级目录，也只更新父对话那一条待办。
            if subagentIDs.contains(sessionID) || isSubagentAudience(at: sessionDir) {
                noteSubagent(sessionID)
                return false
            }
            let summary = try parseSessionDirectory(
                at: sessionDir,
                sessionID: sessionID,
                summaryModifiedAt: summaryMtime,
                eventsModifiedAt: eventsMtime,
                host: liveSessions[path]
            )
            cache[path] = CachedEntry(summary: summary)
            return true
        } catch {
            logger.error(
                "Failed to incrementally parse Grok session \(path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            cache.removeValue(forKey: path)
            return false
        }
    }

    private func cachedSummaries() -> [SessionSummary] {
        Array(cache.values.map(\.summary))
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func retainedHistoryPaths() -> Set<String> {
        Set(cache.values.map(\.summary).filter { $0.runtimeVerified != true }
            .sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxFiles).map(\.filePath))
    }

    private func trimCacheToMaxFiles() {
        let history = retainedHistoryPaths()
        cache = cache.filter { $0.value.summary.runtimeVerified == true || history.contains($0.key) }
        runtime = runtime.filter { cache[$0.key] != nil }
        promptCache = promptCache.filter { cache[$0.key] != nil }
    }

    /// 从任意变更路径向上找到含 summary.json 的 session 目录
    private func sessionDirectory(containing url: URL) -> URL? {
        var current = url
        // 最多向上 4 层:terminal/log → session → encoded-cwd → sessions
        for _ in 0..<5 {
            let summary = current.appending(path: "summary.json")
            if FileManager.default.fileExists(atPath: summary.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private func isLikelyDirectoryEvent(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        return url.pathExtension.isEmpty
    }

    private func parseISO8601(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}
