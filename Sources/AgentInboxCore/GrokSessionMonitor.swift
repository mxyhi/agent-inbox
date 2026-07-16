import Darwin
import Foundation
import OSLog

/// Grok 会话监控器
///
/// 扫描 `~/.grok/sessions/<encoded-cwd>/<session-id>/`,结合:
/// - `summary.json` 元数据
/// - `events.jsonl` 尾部 turn_started / turn_ended
/// - `active_sessions.json` + pid 存活校验
/// - 按需限额读 `updates.jsonl` 取 firstPrompt / lastAgentMessage
///
/// 状态语义(产品锁定):
/// - mid-turn 且 pid 存活 → running
/// - turn 已 ended 且 pid 仍活(等用户输入) → unknown,不展示
/// - 进程退出且曾 completed turn → completed(待办候选)
public actor GrokSessionMonitor {
    /// 缓存指纹:summary/events mtime + pid 存活位,任一变化则重解析
    private struct CacheFingerprint: Equatable {
        let summaryModifiedAt: Date
        let eventsModifiedAt: Date?
        let processAlive: Bool
    }

    private struct CachedEntry {
        let fingerprint: CacheFingerprint
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
        let sessionId: String
        let pid: Int32
        let cwd: String?
        let openedAt: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case pid
            case cwd
            case openedAt = "opened_at"
        }
    }

    private struct EventLine: Decodable {
        let type: String
        let ts: String?
        let outcome: String?
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

    private enum TurnTailState {
        case midTurn(startedAt: Date?)
        case ended(at: Date?, outcome: String?)
        case none
    }

    public nonisolated let sessionsRoot: URL
    public nonisolated let activeSessionsFile: URL
    private let maxFiles: Int
    private let eventsTailByteLimit: UInt64
    private let updatesByteLimit: Int
    private let logger = Logger(subsystem: "agent-inbox", category: "GrokSessionMonitor")

    private let fractionalFormatter: ISO8601DateFormatter
    private let plainFormatter: ISO8601DateFormatter

    /// key = session 目录 path
    private var cache: [String: CachedEntry] = [:]

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".grok/sessions"),
        activeSessionsFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".grok/active_sessions.json"),
        maxFiles: Int = 80,
        eventsTailByteLimit: UInt64 = 128 * 1024,
        updatesByteLimit: Int = 256 * 1024
    ) {
        self.sessionsRoot = sessionsRoot
        self.activeSessionsFile = activeSessionsFile
        self.maxFiles = maxFiles
        self.eventsTailByteLimit = eventsTailByteLimit
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
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            cache.removeAll()
            logger.info("Grok sessions root missing: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        let aliveSessionIDs = loadAliveSessionIDs(fileManager: fileManager)
        let dirs = recentSessionDirectories(fileManager: fileManager)
        var cacheHits = 0
        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(dirs.count)

        for dir in dirs {
            let path = dir.url.path
            let processAlive = aliveSessionIDs.contains(dir.sessionID)
            let fingerprint = CacheFingerprint(
                summaryModifiedAt: dir.summaryModifiedAt,
                eventsModifiedAt: dir.eventsModifiedAt,
                processAlive: processAlive
            )

            if let entry = cache[path], entry.fingerprint == fingerprint {
                summaries.append(entry.summary)
                cacheHits += 1
                continue
            }

            do {
                let summary = try parseSessionDirectory(
                    at: dir.url,
                    sessionID: dir.sessionID,
                    summaryModifiedAt: dir.summaryModifiedAt,
                    eventsModifiedAt: dir.eventsModifiedAt,
                    processAlive: processAlive
                )
                cache[path] = CachedEntry(fingerprint: fingerprint, summary: summary)
                summaries.append(summary)
            } catch {
                logger.error(
                    "Failed to parse Grok session \(path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        let alivePaths = Set(dirs.map(\.url.path))
        cache = cache.filter { alivePaths.contains($0.key) }

        logger.debug(
            "Scanned \(dirs.count, privacy: .public) Grok sessions, cache hits \(cacheHits, privacy: .public), alive \(aliveSessionIDs.count, privacy: .public)"
        )
        return summaries
    }

    /// 增量扫描:命中 session 目录或 active_sessions 时局部刷新;目录级事件回退 full scan
    public func scanChangedPaths(_ changedPaths: [String]) -> [SessionSummary] {
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
            logger.info("Grok sessions root missing during incremental scan")
            return []
        }

        var requiresFullScan = false
        var sessionDirs = Set<String>()
        let sessionsRootPath = sessionsRoot.standardizedFileURL.path
        let activePath = activeSessionsFile.standardizedFileURL.path

        for path in changedPaths {
            let url = URL(filePath: path).standardizedFileURL
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

        let aliveSessionIDs = loadAliveSessionIDs(fileManager: fileManager)
        var reparsed = 0
        for path in sessionDirs {
            if updateCachedSession(at: URL(filePath: path), aliveSessionIDs: aliveSessionIDs, fileManager: fileManager) {
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
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.warning("Unable to enumerate Grok sessions root: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        var dirs: [SessionDirInfo] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "summary.json" else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, let summaryMtime = values.contentModificationDate else {
                    continue
                }
                let sessionDir = url.deletingLastPathComponent()
                let sessionID = sessionDir.lastPathComponent
                guard !sessionID.isEmpty else { continue }

                let eventsURL = sessionDir.appending(path: "events.jsonl")
                let eventsMtime = try? eventsURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate

                dirs.append(
                    SessionDirInfo(
                        url: sessionDir,
                        sessionID: sessionID,
                        summaryModifiedAt: summaryMtime,
                        eventsModifiedAt: eventsMtime
                    )
                )
            } catch {
                logger.error(
                    "Failed to read Grok summary metadata \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        // 按 summary/events 较新者排序
        return Array(
            dirs.sorted { lhs, rhs in
                let left = max(lhs.summaryModifiedAt, lhs.eventsModifiedAt ?? .distantPast)
                let right = max(rhs.summaryModifiedAt, rhs.eventsModifiedAt ?? .distantPast)
                return left > right
            }
            .prefix(maxFiles)
        )
    }

    // MARK: - active_sessions + pid

    /// 读取 active_sessions.json,仅保留 kill(pid,0) 仍存活的 session_id
    private func loadAliveSessionIDs(fileManager: FileManager) -> Set<String> {
        guard fileManager.fileExists(atPath: activeSessionsFile.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: activeSessionsFile)
            let records = try JSONDecoder().decode([ActiveSessionRecord].self, from: data)
            var alive: Set<String> = []
            var zombieCount = 0
            for record in records {
                if isProcessAlive(pid: record.pid) {
                    alive.insert(record.sessionId)
                } else {
                    zombieCount += 1
                }
            }
            if zombieCount > 0 {
                logger.debug("Grok active_sessions has \(zombieCount, privacy: .public) dead pid entries")
            }
            return alive
        } catch {
            logger.error(
                "Failed to read active_sessions: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// 校验 pid 是否仍属于当前用户进程树中的存活进程
    private func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0) 仅检查存在性;EPERM 也表示进程存在
        let result = kill(pid, 0)
        if result == 0 {
            return true
        }
        return errno == EPERM
    }

    // MARK: - 解析

    private func parseSessionDirectory(
        at sessionDir: URL,
        sessionID: String,
        summaryModifiedAt: Date,
        eventsModifiedAt: Date?,
        processAlive: Bool
    ) throws -> SessionSummary {
        let summaryURL = sessionDir.appending(path: "summary.json")
        let summaryData = try Data(contentsOf: summaryURL)
        let summaryFile = try JSONDecoder().decode(SummaryFile.self, from: summaryData)

        let resolvedSessionID = summaryFile.info?.id ?? sessionID
        let cwd = summaryFile.info?.cwd
        let startedAt = summaryFile.createdAt.flatMap { parseISO8601($0) }
        let lastActive = summaryFile.lastActiveAt.flatMap { parseISO8601($0) }
            ?? summaryFile.updatedAt.flatMap { parseISO8601($0) }
        let eventsURL = sessionDir.appending(path: "events.jsonl")
        let turnState = parseTurnTail(eventsURL: eventsURL)
        let eventsMtime = eventsModifiedAt ?? summaryModifiedAt
        let modifiedAt = max(summaryModifiedAt, eventsMtime, lastActive ?? .distantPast)

        let lifecycle: TurnLifecycleState
        let taskCompletedAt: Date?

        switch turnState {
        case .midTurn:
            // 仅进程存活才算运行中;死进程 mid-turn 视为崩溃,不展示
            lifecycle = processAlive ? .running : .unknown
            taskCompletedAt = nil
        case let .ended(at, outcome):
            if processAlive {
                // 等用户输入:不算运行中也不算待办
                lifecycle = .unknown
                taskCompletedAt = nil
            } else if outcome == nil || outcome == "completed" {
                lifecycle = .completed
                taskCompletedAt = at ?? lastActive ?? modifiedAt
            } else {
                lifecycle = .aborted
                taskCompletedAt = nil
            }
        case .none:
            lifecycle = .unknown
            taskCompletedAt = nil
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
            "Parsed Grok session \(resolvedSessionID, privacy: .public): lifecycle=\(finalLifecycle.rawValue, privacy: .public), alive=\(processAlive, privacy: .public)"
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
            firstPrompt: firstPrompt
        )
    }

    /// 从 events.jsonl 尾部找最近 turn_started / turn_ended
    private func parseTurnTail(eventsURL: URL) -> TurnTailState {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else {
            return .none
        }

        do {
            let handle = try FileHandle(forReadingFrom: eventsURL)
            defer { try? handle.close() }

            guard let size = try? handle.seekToEnd() else { return .none }
            let offset = size > eventsTailByteLimit ? size - eventsTailByteLimit : 0
            guard (try? handle.seek(toOffset: offset)) != nil,
                  var data = try? handle.readToEnd() else {
                return .none
            }

            if offset > 0 {
                if let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) {
                    data = Data(data.suffix(from: firstNewline + 1))
                } else {
                    data = Data()
                }
            }

            guard let text = String(data: data, encoding: .utf8) else { return .none }
            let decoder = JSONDecoder()

            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard line.contains("turn_started") || line.contains("turn_ended") else { continue }
                guard let event = try? decoder.decode(EventLine.self, from: Data(line.utf8)) else {
                    continue
                }
                let ts = event.ts.flatMap { parseISO8601($0) }
                switch event.type {
                case "turn_ended":
                    return .ended(at: ts, outcome: event.outcome)
                case "turn_started":
                    return .midTurn(startedAt: ts)
                default:
                    continue
                }
            }
            return .none
        } catch {
            logger.error(
                "Failed to read events.jsonl \(eventsURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return .none
        }
    }

    /// 限额扫描 updates.jsonl:首个 user_message_chunk + 最近一轮 agent_message_chunk
    private func parsePrompts(updatesURL: URL) -> (first: String?, last: String?) {
        guard FileManager.default.fileExists(atPath: updatesURL.path) else {
            return (nil, nil)
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
        aliveSessionIDs: Set<String>,
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
            let processAlive = aliveSessionIDs.contains(sessionID)
            let fingerprint = CacheFingerprint(
                summaryModifiedAt: summaryMtime,
                eventsModifiedAt: eventsMtime,
                processAlive: processAlive
            )
            if let entry = cache[path], entry.fingerprint == fingerprint {
                return false
            }

            let summary = try parseSessionDirectory(
                at: sessionDir,
                sessionID: sessionID,
                summaryModifiedAt: summaryMtime,
                eventsModifiedAt: eventsMtime,
                processAlive: processAlive
            )
            cache[path] = CachedEntry(fingerprint: fingerprint, summary: summary)
            return true
        } catch {
            logger.error(
                "Failed to incrementally parse Grok session \(path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            if !fileManager.fileExists(atPath: path) {
                cache.removeValue(forKey: path)
            }
            return false
        }
    }

    private func cachedSummaries() -> [SessionSummary] {
        Array(cache.values.map(\.summary))
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .map { $0 }
    }

    private func trimCacheToMaxFiles() {
        let keepPaths = Set(
            cache
                .sorted { $0.value.summary.modifiedAt > $1.value.summary.modifiedAt }
                .prefix(maxFiles)
                .map(\.key)
        )
        cache = cache.filter { keepPaths.contains($0.key) }
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
