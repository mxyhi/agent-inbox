import Foundation
import OSLog

/// Claude Code transcript 会话监控器。
///
/// Claude Code 将每个项目的会话直接写入 `~/.claude/projects/<encoded-cwd>/`。
/// transcript 只负责保存对话，运行态再用 `claude agents --json` 补齐；CLI 不可用时
/// 仍可从 transcript 尾部的 stop_hook_summary/turn_duration 判定待办。
public actor ClaudeSessionMonitor {
    private struct TranscriptFile {
        let url: URL
        let modifiedAt: Date
    }

    private struct CachedEntry {
        let modifiedAt: Date
        let parsed: ParsedTranscript
    }

    private struct ParsedTranscript {
        let sessionID: String
        let cwd: String?
        let startedAt: Date?
        let firstPrompt: String?
        let lastAgentMessage: String?
        let tailState: TailState
    }

    private enum TailState {
        case active
        case completed(Date?)
        case unknown
    }

    private enum LiveStatus {
        case active
        case idle
    }

    private struct LiveSessionRecord: Decodable {
        let sessionID: String
        let status: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "sessionId"
            case status
        }
    }

    private struct TranscriptLine: Decodable {
        let type: String?
        let subtype: String?
        let sessionID: String?
        let alternateSessionID: String?
        let cwd: String?
        let timestamp: String?
        let isMeta: Bool?
        let message: ClaudeMessage?

        enum CodingKeys: String, CodingKey {
            case type
            case subtype
            case sessionID = "sessionId"
            case alternateSessionID = "session_id"
            case cwd
            case timestamp
            case isMeta
            case message
        }

        var resolvedSessionID: String? {
            sessionID ?? alternateSessionID
        }
    }

    private struct ClaudeMessage: Decodable {
        let role: String?
        let content: MessageContent?
    }

    private struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }

    /// Claude user message 可为字符串，assistant message 通常为 content block 数组。
    private enum MessageContent: Decodable {
        case text(String)
        case blocks([ContentBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([ContentBlock].self))
            }
        }

        var textValue: String? {
            switch self {
            case let .text(text):
                return text
            case let .blocks(blocks):
                let text = blocks
                    .filter { $0.type == "text" }
                    .compactMap(\.text)
                    .joined()
                return text.isEmpty ? nil : text
            }
        }
    }

    public nonisolated let sessionsRoot: URL
    private let maxFiles: Int
    private let headByteLimit: Int
    private let tailByteLimit: UInt64
    private let queriesLiveSessions: Bool
    private let claudeExecutableOverride: URL?
    private let logger = Logger(subsystem: "agent-inbox", category: "ClaudeSessionMonitor")
    private let fractionalFormatter: ISO8601DateFormatter
    private let plainFormatter: ISO8601DateFormatter
    private let liveStatusCacheInterval: TimeInterval = 2

    private var cache: [String: CachedEntry] = [:]
    private var liveStatusCache: [String: LiveStatus] = [:]
    private var liveStatusLoadedAt = Date.distantPast

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects"),
        maxFiles: Int = 80,
        headByteLimit: Int = 256 * 1024,
        tailByteLimit: UInt64 = 256 * 1024,
        queriesLiveSessions: Bool = true,
        claudeExecutableURL: URL? = nil
    ) {
        self.sessionsRoot = sessionsRoot
        self.maxFiles = maxFiles
        self.headByteLimit = headByteLimit
        self.tailByteLimit = tailByteLimit
        self.queriesLiveSessions = queriesLiveSessions
        self.claudeExecutableOverride = claudeExecutableURL

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalFormatter = fractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plainFormatter = plain
    }

    /// 扫描最近 transcript；文件 mtime 未变时只复用解析结果，live 状态按短 TTL 刷新。
    public func scan() -> [SessionSummary] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            cache.removeAll()
            logger.info("Claude sessions root missing: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        let liveStatuses = loadLiveStatusesIfNeeded(fileManager: fileManager)
        let files = recentTranscriptFiles(fileManager: fileManager)
        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(files.count)
        var cacheHits = 0

        for file in files {
            let path = file.url.path
            let parsed: ParsedTranscript
            if let entry = cache[path], entry.modifiedAt == file.modifiedAt {
                parsed = entry.parsed
                cacheHits += 1
            } else {
                do {
                    parsed = try parseTranscript(at: file.url, modifiedAt: file.modifiedAt)
                    cache[path] = CachedEntry(modifiedAt: file.modifiedAt, parsed: parsed)
                } catch {
                    logger.error(
                        "Failed to parse Claude transcript \(path, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    continue
                }
            }

            summaries.append(
                makeSummary(
                    parsed: parsed,
                    file: file,
                    liveStatus: liveStatuses[parsed.sessionID]
                )
            )
        }

        let alivePaths = Set(files.map(\.url.path))
        cache = cache.filter { alivePaths.contains($0.key) }
        logger.debug(
            "Scanned \(files.count, privacy: .public) Claude transcripts, cache hits \(cacheHits, privacy: .public), live \(liveStatuses.count, privacy: .public)"
        )
        return summaries
    }

    /// 增量扫描 transcript；live 状态变化会重新投影全部缓存摘要，但不会重读未变文件。
    public func scanChangedPaths(_ changedPaths: [String]) -> [SessionSummary] {
        guard !changedPaths.isEmpty else {
            return cachedSummaries(liveStatuses: liveStatusCache)
        }
        guard !cache.isEmpty else {
            logger.debug("Claude incremental scan before cache warm-up; full scan")
            return scan()
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            cache.removeAll()
            logger.info("Claude sessions root missing during incremental scan")
            return []
        }

        var transcriptPaths = Set<String>()
        var requiresFullScan = false
        for path in changedPaths {
            let url = URL(filePath: path).standardizedFileURL
            if isTranscriptFile(url) {
                transcriptPaths.insert(url.path)
            } else if isProjectDirectoryEvent(url, fileManager: fileManager) {
                requiresFullScan = true
                break
            }
        }

        if requiresFullScan {
            logger.debug("Claude directory-level change; falling back to full scan")
            return scan()
        }

        for path in transcriptPaths {
            updateCachedTranscript(at: URL(filePath: path), fileManager: fileManager)
        }
        let liveStatuses = loadLiveStatusesIfNeeded(fileManager: fileManager)
        let summaries = cachedSummaries(liveStatuses: liveStatuses)
        logger.debug(
            "Incrementally scanned \(transcriptPaths.count, privacy: .public) Claude transcripts"
        )
        return summaries
    }

    // MARK: - 文件枚举

    private func recentTranscriptFiles(fileManager: FileManager) -> [TranscriptFile] {
        let projectURLs: [URL]
        do {
            projectURLs = try fileManager.contentsOfDirectory(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger.warning(
                "Unable to enumerate Claude sessions root: \(String(describing: error), privacy: .public)"
            )
            return []
        }

        var files: [TranscriptFile] = []
        for projectURL in projectURLs {
            do {
                let projectValues = try projectURL.resourceValues(forKeys: [.isDirectoryKey])
                guard projectValues.isDirectory == true else { continue }
                let transcriptURLs = try fileManager.contentsOfDirectory(
                    at: projectURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                for url in transcriptURLs where url.pathExtension == "jsonl" {
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else {
                        continue
                    }
                    files.append(TranscriptFile(url: url, modifiedAt: modifiedAt))
                }
            } catch {
                logger.error(
                    "Failed to enumerate Claude project \(projectURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        return Array(files.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxFiles))
    }

    private func isTranscriptFile(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        let root = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let projectRoot = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return projectRoot == root
    }

    /// 只让 projects 根或其直属项目目录触发全扫；更深层均是 subagent/tool-results 等噪声。
    private func isProjectDirectoryEvent(_ url: URL, fileManager: FileManager) -> Bool {
        let root = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved == root || resolved.deletingLastPathComponent() == root else {
            return false
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        return url.pathExtension.isEmpty
    }

    private func updateCachedTranscript(at url: URL, fileManager: FileManager) {
        let path = url.path
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else {
                cache.removeValue(forKey: path)
                return
            }
            guard let previous = cache[path], previous.modifiedAt == modifiedAt else {
                let parsed = try parseTranscript(at: url, modifiedAt: modifiedAt)
                cache[path] = CachedEntry(modifiedAt: modifiedAt, parsed: parsed)
                return
            }
            cache[path] = previous
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            cache.removeValue(forKey: path)
        } catch {
            logger.error(
                "Failed to incrementally parse Claude transcript \(path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            if !fileManager.fileExists(atPath: path) {
                cache.removeValue(forKey: path)
            }
        }
    }

    // MARK: - Transcript 解析

    private func parseTranscript(at url: URL, modifiedAt: Date) throws -> ParsedTranscript {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let headData = try handle.read(upToCount: headByteLimit) ?? Data()
        let head = parseHead(data: headData)
        let tail = try parseTail(handle: handle, modifiedAt: modifiedAt)
        let fallbackID = url.deletingPathExtension().lastPathComponent
        return ParsedTranscript(
            sessionID: head.sessionID ?? fallbackID,
            cwd: head.cwd,
            startedAt: head.startedAt,
            firstPrompt: head.firstPrompt,
            lastAgentMessage: tail.lastAgentMessage,
            tailState: tail.state
        )
    }

    private struct HeadInfo {
        var sessionID: String?
        var cwd: String?
        var startedAt: Date?
        var firstPrompt: String?
    }

    private func parseHead(data: Data) -> HeadInfo {
        guard !data.isEmpty else { return HeadInfo() }
        let completeData: Data
        if data.count >= headByteLimit, let newline = data.lastIndex(of: UInt8(ascii: "\n")) {
            completeData = Data(data.prefix(upTo: newline))
        } else {
            completeData = data
        }
        guard let text = String(data: completeData, encoding: .utf8) else {
            logger.warning("Claude transcript head is not valid UTF-8")
            return HeadInfo()
        }

        var info = HeadInfo()
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let parsed = try? decoder.decode(TranscriptLine.self, from: Data(line.utf8)) else { continue }
            if info.sessionID == nil {
                info.sessionID = parsed.resolvedSessionID
            }
            if info.cwd == nil, let cwd = parsed.cwd, !cwd.isEmpty {
                info.cwd = cwd
            }
            if info.startedAt == nil, let timestamp = parsed.timestamp {
                info.startedAt = parseISO8601(timestamp)
            }
            guard info.firstPrompt == nil,
                  parsed.type == "user",
                  parsed.isMeta != true,
                  let message = parsed.message,
                  let content = message.content?.textValue,
                  !isSyntheticTitle(content) else {
                continue
            }
            info.firstPrompt = sanitizePrompt(content)
        }
        logger.debug(
            "Parsed Claude transcript head: session=\(info.sessionID ?? "unknown", privacy: .public), prompt=\(info.firstPrompt == nil ? "missing" : "captured", privacy: .public)"
        )
        return info
    }

    private struct TailInfo {
        var state: TailState = .unknown
        var lastAgentMessage: String?
    }

    private func parseTail(handle: FileHandle, modifiedAt: Date) throws -> TailInfo {
        let size = try handle.seekToEnd()
        let offset = size > tailByteLimit ? size - tailByteLimit : 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        if offset > 0 {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
                return TailInfo()
            }
            data = Data(data.suffix(from: newline + 1))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            logger.warning("Claude transcript tail is not valid UTF-8")
            return TailInfo()
        }

        var tail = TailInfo()
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let parsed = try? decoder.decode(TranscriptLine.self, from: Data(line.utf8)) else { continue }
            if parsed.type == "assistant" {
                tail.state = .active
                if let text = parsed.message?.content?.textValue,
                   let message = sanitizeAgentMessage(text) {
                    tail.lastAgentMessage = message
                }
            } else if parsed.type == "user" {
                tail.state = .active
            } else if parsed.type == "system",
                      parsed.subtype == "stop_hook_summary" || parsed.subtype == "turn_duration" {
                tail.state = .completed(parsed.timestamp.flatMap(parseISO8601) ?? modifiedAt)
            }
        }
        return tail
    }

    // MARK: - 状态投影

    private func makeSummary(
        parsed: ParsedTranscript,
        file: TranscriptFile,
        liveStatus: LiveStatus?
    ) -> SessionSummary {
        let lifecycle: TurnLifecycleState
        let completedAt: Date?
        switch liveStatus {
        case .active:
            lifecycle = .running
            completedAt = nil
        case .idle:
            lifecycle = .completed
            completedAt = completionDate(from: parsed.tailState, fallback: file.modifiedAt)
        case nil:
            switch parsed.tailState {
            case let .completed(date):
                lifecycle = .completed
                completedAt = date
            case .active:
                lifecycle = .running
                completedAt = nil
            case .unknown:
                lifecycle = .unknown
                completedAt = nil
            }
        }

        return SessionSummary(
            provider: .claude,
            sessionID: parsed.sessionID,
            filePath: file.url.path,
            cwd: parsed.cwd,
            startedAt: parsed.startedAt,
            modifiedAt: file.modifiedAt,
            lifecycleState: lifecycle,
            taskCompletedAt: completedAt,
            lastAgentMessage: parsed.lastAgentMessage,
            firstPrompt: parsed.firstPrompt
        )
    }

    private func completionDate(from state: TailState, fallback: Date) -> Date {
        if case let .completed(date) = state {
            return date ?? fallback
        }
        return fallback
    }

    private func cachedSummaries(liveStatuses: [String: LiveStatus] = [:]) -> [SessionSummary] {
        cache
            .sorted { $0.value.modifiedAt > $1.value.modifiedAt }
            .prefix(maxFiles)
            .map { path, entry in
                makeSummary(
                    parsed: entry.parsed,
                    file: TranscriptFile(url: URL(filePath: path), modifiedAt: entry.modifiedAt),
                    liveStatus: liveStatuses[entry.parsed.sessionID]
                )
            }
    }

    // MARK: - Claude CLI live 状态

    private func loadLiveStatusesIfNeeded(fileManager: FileManager) -> [String: LiveStatus] {
        guard queriesLiveSessions else { return [:] }
        let now = Date()
        guard now.timeIntervalSince(liveStatusLoadedAt) >= liveStatusCacheInterval else {
            return liveStatusCache
        }
        liveStatusLoadedAt = now
        guard let executable = claudeExecutable(fileManager: fileManager) else {
            liveStatusCache = [:]
            logger.info("Claude CLI not found; using transcript lifecycle only")
            return liveStatusCache
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["agents", "--json"]
        var environment = ProcessInfo.processInfo.environment
        // Agent Inbox 可能从 Claude Code 终端启动；移除嵌套标记，避免只读 agents 查询被拒绝。
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = environment
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
                logger.warning(
                    "Claude agents command failed: status=\(process.terminationStatus)"
                )
                liveStatusCache = [:]
                return liveStatusCache
            }

            let records = try JSONDecoder().decode([LiveSessionRecord].self, from: output)
            liveStatusCache = records.reduce(into: [String: LiveStatus]()) { statuses, record in
                guard let status = parseLiveStatus(record.status) else { return }
                statuses[record.sessionID] = status
            }
            return liveStatusCache
        } catch {
            logger.warning("Failed to query Claude live sessions: \(String(describing: error), privacy: .public)")
            liveStatusCache = [:]
            return liveStatusCache
        }
    }

    private func claudeExecutable(fileManager: FileManager) -> URL? {
        if let claudeExecutableOverride,
           fileManager.isExecutableFile(atPath: claudeExecutableOverride.path) {
            return claudeExecutableOverride
        }

        let pathCandidates = [
            ProcessInfo.processInfo.environment["PATH"]?
                .split(separator: ":")
                .map { String($0) } ?? [],
            [
                fileManager.homeDirectoryForCurrentUser.appending(path: "Library/pnpm/bin").path,
                fileManager.homeDirectoryForCurrentUser.appending(path: ".superconductor/bin").path,
                fileManager.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
                "/opt/homebrew/bin",
                "/usr/local/bin"
            ]
        ].flatMap { $0 }

        for directory in pathCandidates {
            let candidate = URL(filePath: directory).appending(path: "claude")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func parseLiveStatus(_ raw: String?) -> LiveStatus? {
        switch raw?.lowercased() {
        case "active", "running", "busy", "working":
            .active
        case "idle", "waiting":
            .idle
        default:
            nil
        }
    }

    // MARK: - 文本与时间

    private func isSyntheticTitle(_ text: String) -> Bool {
        text.contains("Generate a concise tab title for this chat.")
    }

    private func sanitizePrompt(_ text: String) -> String? {
        let ignoredPrefixes = [
            "<local-command-caveat>",
            "<command-name>",
            "<command-message>",
            "<command-args>",
            "<local-command-stdout>"
        ]
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { value in
                !value.isEmpty && !ignoredPrefixes.contains { value.hasPrefix($0) }
            }
        guard let line else { return nil }
        return line.count > 200 ? "\(line.prefix(200))…" : line
    }

    private func sanitizeAgentMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 500 ? "\(trimmed.prefix(500))…" : trimmed
    }

    private func parseISO8601(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}
