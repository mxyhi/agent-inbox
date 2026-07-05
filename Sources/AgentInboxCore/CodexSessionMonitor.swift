import Foundation
import OSLog

/// Codex rollout 会话监控器(V4)
///
/// 扫描 `~/.codex/sessions` 下最近的 rollout jsonl 文件,产出 `CodexSessionSummary`。
/// 设计为 actor 的原因:
/// - 扫描与解析全部运行在 actor 的后台 executor 上,主线程零文件 IO;
/// - actor 隔离天然保护 mtime 缓存的并发安全,mtime 未变的文件直接命中缓存、跳过解析。
public actor CodexSessionMonitor {
    /// 缓存条目:文件 mtime + 上次解析出的摘要
    private struct CachedEntry {
        let modifiedAt: Date
        let summary: CodexSessionSummary
    }

    /// rollout 单行外层信封(head/tail 共用),只解码判定所需的字段
    private struct RolloutLine: Decodable {
        let timestamp: String?
        let type: String
        let payload: RolloutPayload?
    }

    /// rollout 行 payload:session_meta 与 task_complete 两类字段的并集
    private struct RolloutPayload: Decodable {
        /// session_meta:会话 ID(真实数据 id 与 session_id 并存,优先 id)
        let id: String?
        let sessionId: String?
        /// event_msg 的事件子类型,如 task_complete
        let type: String?
        /// session_meta:会话工作目录
        let cwd: String?
        /// session_meta:会话启动时间(ISO8601,带小数秒)
        let timestamp: String?
        /// task_complete:agent 最后一条消息(可能长达数百字符且含换行)
        let lastAgentMessage: String?

        enum CodingKeys: String, CodingKey {
            case id
            case sessionId = "session_id"
            case type
            case cwd
            case timestamp
            case lastAgentMessage = "last_agent_message"
        }
    }

    /// head 解析结果:session_meta 三元组
    private struct HeadInfo {
        var sessionID: String?
        var cwd: String?
        var startedAt: Date?
    }

    /// tail 解析结果:最近 lifecycle event 与 task_complete 附带信息
    private struct TailInfo {
        var lifecycleState: CodexTurnLifecycleState = .unknown
        var taskCompletedAt: Date?
        var lastAgentMessage: String?
    }

    public nonisolated let sessionsRoot: URL
    private let maxFiles: Int
    private let headByteLimit: Int
    private let tailByteLimit: UInt64
    private let logger = Logger(subsystem: "agent-inbox", category: "CodexSessionMonitor")

    /// 主解析器:真实 rollout 时间戳带毫秒(如 "2026-07-04T14:23:29.440Z")。
    /// ⚠️ ISO8601DateFormatter 默认配置不支持小数秒(旧版扫描器因此永远解析失败),
    /// 必须显式开启 .withFractionalSeconds。
    private let fractionalFormatter: ISO8601DateFormatter
    /// 兜底解析器:处理不带小数秒的时间戳(如 "2026-07-04T14:23:29Z")
    private let plainFormatter: ISO8601DateFormatter

    /// mtime 缓存,key 为文件路径;actor 隔离保证并发安全
    private var cache: [String: CachedEntry] = [:]

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions"),
        maxFiles: Int = 80,
        // 真实 session_meta 首行含 base_instructions 全文,2026-07-04 实测 13–22KB,取 64KB 留足裕量
        headByteLimit: Int = 64 * 1024,
        tailByteLimit: UInt64 = 256 * 1024
    ) {
        self.sessionsRoot = sessionsRoot
        self.maxFiles = maxFiles
        self.headByteLimit = headByteLimit
        self.tailByteLimit = tailByteLimit

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalFormatter = fractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plainFormatter = plain
    }

    /// 扫描最近 rollout 文件,返回会话摘要(mtime 未变的文件直接命中缓存,不重新解析)
    public func scan() -> [CodexSessionSummary] {
        // FileManager 非 Sendable,不作为属性持有,方法内局部使用共享实例
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            logger.info("Codex sessions root missing: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        let files = recentRolloutFiles(fileManager: fileManager)
        var cacheHits = 0
        var summaries: [CodexSessionSummary] = []
        summaries.reserveCapacity(files.count)

        for file in files {
            let path = file.url.path
            // mtime 未变 → 内容未变,直接复用上次解析结果
            if let entry = cache[path], entry.modifiedAt == file.modifiedAt {
                summaries.append(entry.summary)
                cacheHits += 1
                continue
            }

            do {
                let summary = try parseRollout(at: file.url, modifiedAt: file.modifiedAt)
                cache[path] = CachedEntry(modifiedAt: file.modifiedAt, summary: summary)
                summaries.append(summary)
            } catch {
                logger.error("Failed to parse rollout \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // 淘汰跌出「最近 maxFiles」窗口的缓存条目,防止缓存无限增长
        let alivePaths = Set(files.map(\.url.path))
        cache = cache.filter { alivePaths.contains($0.key) }

        logger.debug("Scanned \(files.count, privacy: .public) rollout files, cache hits \(cacheHits, privacy: .public)")
        return summaries
    }

    /// 增量扫描 FSEvents 命中的路径:只重读变更的 rollout 文件;目录级事件或空缓存时回退 full scan
    public func scanChangedPaths(_ changedPaths: [String]) -> [CodexSessionSummary] {
        guard !changedPaths.isEmpty else {
            return cachedSummaries()
        }
        guard !cache.isEmpty else {
            logger.debug("Incremental scan requested before cache warm-up; falling back to full scan")
            return scan()
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            cache.removeAll()
            logger.info("Codex sessions root missing during incremental scan: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        var rolloutPaths = Set<String>()
        var requiresFullScan = false

        for path in changedPaths {
            let url = URL(filePath: path).standardizedFileURL
            if isRolloutFile(url) {
                rolloutPaths.insert(url.path)
            } else if isLikelyDirectoryEvent(url, fileManager: fileManager) {
                requiresFullScan = true
            }
        }

        if requiresFullScan {
            logger.debug("Directory-level FSEvents change; falling back to full scan")
            return scan()
        }
        guard !rolloutPaths.isEmpty else {
            return cachedSummaries()
        }

        var reparsed = 0
        for path in rolloutPaths {
            if updateCachedRollout(at: URL(filePath: path), fileManager: fileManager) {
                reparsed += 1
            }
        }
        trimCacheToMaxFiles()

        logger.debug("Incrementally scanned \(rolloutPaths.count, privacy: .public) rollout paths, reparsed \(reparsed, privacy: .public)")
        return cachedSummaries()
    }

    // MARK: - 文件枚举

    /// 枚举 sessionsRoot 下全部 rollout-*.jsonl,按 mtime 降序取前 maxFiles 个
    private func recentRolloutFiles(fileManager: FileManager) -> [(url: URL, modifiedAt: Date)] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.warning("Unable to enumerate Codex sessions root: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            // 只关心 rollout-*.jsonl 会话文件
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else {
                continue
            }
            do {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else {
                    continue
                }
                files.append((url, modifiedAt))
            } catch {
                logger.error("Failed to read rollout metadata \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        return Array(files.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxFiles))
    }

    private func updateCachedRollout(at url: URL, fileManager: FileManager) -> Bool {
        let path = url.path
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else {
                cache.removeValue(forKey: path)
                return false
            }
            if let entry = cache[path], entry.modifiedAt == modifiedAt {
                return false
            }

            let summary = try parseRollout(at: url, modifiedAt: modifiedAt)
            cache[path] = CachedEntry(modifiedAt: modifiedAt, summary: summary)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            cache.removeValue(forKey: path)
            return false
        } catch {
            logger.error("Failed to incrementally parse rollout \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            if !fileManager.fileExists(atPath: path) {
                cache.removeValue(forKey: path)
            }
            return false
        }
    }

    private func cachedSummaries() -> [CodexSessionSummary] {
        Array(cache.values.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxFiles))
            .map(\.summary)
    }

    private func trimCacheToMaxFiles() {
        let keepPaths = Set(
            cache
                .sorted { $0.value.modifiedAt > $1.value.modifiedAt }
                .prefix(maxFiles)
                .map(\.key)
        )
        cache = cache.filter { keepPaths.contains($0.key) }
    }

    private func isRolloutFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl"
    }

    private func isLikelyDirectoryEvent(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        // FSEvents can report deleted/renamed directories after they no longer exist.
        return url.pathExtension.isEmpty
    }

    // MARK: - 单文件解析

    /// 解析单个 rollout 文件:head 取 session_meta(id/cwd/startedAt),tail 取最近生命周期事件
    private func parseRollout(at url: URL, modifiedAt: Date) throws -> CodexSessionSummary {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        let head = parseHead(handle: handle, decoder: decoder, url: url)
        let tail = parseTail(handle: handle, decoder: decoder, url: url, modifiedAt: modifiedAt)

        return CodexSessionSummary(
            // 首行缺 session_meta 或解析失败时,退化为文件名(去扩展名)作为稳定 ID
            id: head.sessionID ?? url.deletingPathExtension().lastPathComponent,
            filePath: url.path,
            cwd: head.cwd,
            startedAt: head.startedAt,
            modifiedAt: modifiedAt,
            lifecycleState: tail.lifecycleState,
            taskCompletedAt: tail.taskCompletedAt,
            lastAgentMessage: tail.lastAgentMessage
        )
    }

    /// 读文件头 headByteLimit 字节内的第一行,解析 session_meta → id/cwd/startedAt
    private func parseHead(handle: FileHandle, decoder: JSONDecoder, url: URL) -> HeadInfo {
        guard let raw = try? handle.read(upToCount: headByteLimit), !raw.isEmpty else {
            logger.warning("Failed to read rollout head: \(url.path, privacy: .public)")
            return HeadInfo()
        }

        // 截取第一个换行前的内容作为首行;无换行时(无结尾换行的单行小文件)整段尝试解析
        let firstLine: Data
        if let newline = raw.firstIndex(of: UInt8(ascii: "\n")) {
            firstLine = Data(raw.prefix(upTo: newline))
        } else {
            firstLine = raw
        }

        guard let line = try? decoder.decode(RolloutLine.self, from: firstLine),
              line.type == "session_meta",
              let payload = line.payload else {
            // 首行不是 session_meta(或超出 headByteLimit 被截断),各字段置 nil,由调用方 fallback
            logger.warning("Rollout head is not a valid session_meta: \(url.path, privacy: .public)")
            return HeadInfo()
        }

        return HeadInfo(
            sessionID: payload.id ?? payload.sessionId, // 真实数据两者并存,优先 id
            cwd: payload.cwd,
            startedAt: payload.timestamp.flatMap { parseISO8601($0) } // payload.timestamp 为会话启动时间
        )
    }

    /// 读文件尾 tailByteLimit 字节,从后向前找最近 lifecycle event(一个文件可能承载多轮任务)
    private func parseTail(handle: FileHandle, decoder: JSONDecoder, url: URL, modifiedAt: Date) -> TailInfo {
        guard let size = try? handle.seekToEnd() else {
            logger.warning("Failed to determine rollout size: \(url.path, privacy: .public)")
            return TailInfo()
        }

        let offset = size > tailByteLimit ? size - tailByteLimit : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              var data = try? handle.readToEnd() else {
            logger.warning("Failed to read rollout tail: \(url.path, privacy: .public)")
            return TailInfo()
        }

        if offset > 0 {
            // 从文件中间起读:首行大概率被截断(甚至切在多字节 UTF-8 字符中间),
            // 在字节层面丢弃第一个换行符之前的内容,保证后续 UTF-8 解码与逐行解析安全
            if let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) {
                data = Data(data.suffix(from: firstNewline + 1))
            } else {
                data = Data() // 窗口内没有任何完整行
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            logger.warning("Rollout tail is not valid UTF-8: \(url.path, privacy: .public)")
            return TailInfo()
        }

        // 从后向前找第一个 lifecycle 命中,即当前 turn 的最新官方状态。
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            // 子串预筛:绝大多数行与 lifecycle 无关,避免逐行 JSON 解码的开销
            guard
                line.contains("\"task_started\"")
                    || line.contains("\"turn_started\"")
                    || line.contains("\"task_complete\"")
                    || line.contains("\"turn_complete\"")
                    || line.contains("\"turn_aborted\"")
                    || line.contains("\"thread_rolled_back\"")
            else { continue }
            guard let parsed = try? decoder.decode(RolloutLine.self, from: Data(line.utf8)),
                  parsed.type == "event_msg",
                  let eventType = parsed.payload?.type else {
                continue
            }

            switch eventType {
            case "task_started", "turn_started":
                return TailInfo(lifecycleState: .running)
            case "task_complete", "turn_complete":
                // 完成时间优先取事件外层 timestamp(真实数据 payload 内没有 completed_at 字段);
                // timestamp 缺失或解析失败时 fallback 到文件 mtime
                return TailInfo(
                    lifecycleState: .completed,
                    taskCompletedAt: parsed.timestamp.flatMap { parseISO8601($0) } ?? modifiedAt,
                    lastAgentMessage: parsed.payload?.lastAgentMessage
                )
            case "turn_aborted":
                return TailInfo(lifecycleState: .aborted)
            case "thread_rolled_back":
                return TailInfo(lifecycleState: .rolledBack)
            default:
                continue
            }
        }

        // 尾部可能只有普通 message/tool 事件;保留旧 fresh-mtime 运行候选,避免长任务漏报。
        return TailInfo(lifecycleState: .running)
    }

    // MARK: - 时间戳解析

    /// 解析 rollout ISO8601 时间戳:先按带小数秒解析(真实数据为毫秒精度),失败再按整秒兜底
    private func parseISO8601(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}
