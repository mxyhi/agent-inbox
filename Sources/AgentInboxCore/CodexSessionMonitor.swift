import Foundation
import OSLog

/// Codex rollout 会话监控器
///
/// 扫描 `~/.codex/sessions` 下最近的 rollout jsonl 文件,产出 `SessionSummary`(provider=.codex)。
/// 设计为 actor 的原因:
/// - 扫描与解析全部运行在 actor 的后台 executor 上,主线程零文件 IO;
/// - actor 隔离天然保护 mtime 缓存的并发安全,mtime 未变的文件直接命中缓存、跳过解析。
public actor CodexSessionMonitor {
    /// 缓存条目:mtime + 文件身份 + 已提交的解析偏移与状态。
    private struct CachedEntry {
        let modifiedAt: Date
        let summary: SessionSummary
        let fileNumber: UInt64?
        let fileSize: UInt64
        let state: CodexRolloutState
    }

    /// rollout 头部信封，仅解码会话身份与首个提示词所需字段。
    private struct RolloutLine: Decodable {
        let timestamp: String?
        let type: String
        let payload: RolloutPayload?
    }

    /// 文件头中的 session_meta / user_message 字段。
    private struct RolloutPayload: Decodable {
        /// session_meta:会话 ID(真实数据 id 与 session_id 并存,优先 id)
        let id: String?
        let sessionId: String?
        /// event_msg 的事件子类型,如 task_complete / user_message
        let type: String?
        /// session_meta:会话工作目录
        let cwd: String?
        /// session_meta:会话启动时间(ISO8601,带小数秒)
        let timestamp: String?
        /// task_complete:agent 最后一条消息(可能长达数百字符且含换行)
        let lastAgentMessage: String?
        /// user_message:用户输入原文(可能是几 KB 的终端粘贴,含多行/ASCII art),存前需清洗截断
        let message: String?

        enum CodingKeys: String, CodingKey {
            case id
            case sessionId = "session_id"
            case type
            case cwd
            case timestamp
            case lastAgentMessage = "last_agent_message"
            case message
        }
    }

    /// head 解析结果:session_meta 三元组 + 首个用户提示词
    private struct HeadInfo {
        var sessionID: String?
        var cwd: String?
        var startedAt: Date?
        /// 首个 event_msg/user_message 的清洗后提示词;nil = head 窗口内未捕获到用户输入
        var firstPrompt: String?
    }

    public nonisolated let sessionsRoot: URL
    private let maxFiles: Int
    private let headByteLimit: Int
    private let logger = Logger(subsystem: "agent-inbox", category: "CodexSessionMonitor")

    /// 主解析器:真实 rollout 时间戳带毫秒(如 "2026-07-04T14:23:29.440Z")。
    /// ⚠️ ISO8601DateFormatter 默认配置不支持小数秒(旧版扫描器因此永远解析失败),
    /// 必须显式开启 .withFractionalSeconds。
    private let fractionalFormatter: ISO8601DateFormatter
    /// 兜底解析器:处理不带小数秒的时间戳(如 "2026-07-04T14:23:29Z")
    private let plainFormatter: ISO8601DateFormatter

    /// mtime 缓存,key 为文件路径;actor 隔离保证并发安全
    private var cache: [String: CachedEntry] = [:]
    /// 已经打过「丢弃旧 rollout」日志的路径。续写追加会反复扫描，不能每轮都打。
    private var loggedDroppedRollouts: Set<String> = []
    /// 上次记录的子线程跳过数。数量不变时不重复打日志。
    private var lastLoggedSkippedChildThreads = 0

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions"),
        maxFiles: Int = 80,
        // head 需覆盖到首个 user_message:真提示词稳定落在 ~90KB–114KB 处(前面 developer/permissions
        // ~47KB、AGENTS.md ~11KB、turn_context ~13KB 把它顶下去),故取 256KB 才能扫到
        headByteLimit: Int = 256 * 1024
    ) {
        // macOS 的 /var 与 /private/var 可指向同一文件，扫描与 FSEvents 必须共用缓存键。
        self.sessionsRoot = sessionsRoot.resolvingSymlinksInPath()
        self.maxFiles = maxFiles
        self.headByteLimit = headByteLimit

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalFormatter = fractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plainFormatter = plain
    }

    /// 扫描最近 rollout 文件,返回会话摘要(mtime 未变的文件直接命中缓存,不重新解析)
    public func scan() -> [SessionSummary] {
        // FileManager 非 Sendable,不作为属性持有,方法内局部使用共享实例
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            logger.info("Codex sessions root missing: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        let files = recentRolloutFiles(fileManager: fileManager)
        var cacheHits = 0
        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(files.count)

        for file in files {
            let path = file.url.resolvingSymlinksInPath().path
            // mtime 未变 → 内容未变,直接复用上次解析结果
            if let entry = cache[path], entry.modifiedAt == file.modifiedAt {
                summaries.append(entry.summary)
                cacheHits += 1
                continue
            }

            do {
                let entry = try parseRollout(at: file.url, modifiedAt: file.modifiedAt)
                cache[path] = entry
                summaries.append(entry.summary)
            } catch {
                logger.error("Failed to parse rollout \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // 淘汰跌出「最近 maxFiles」窗口的缓存条目,防止缓存无限增长
        let alivePaths = Set(files.map { $0.url.resolvingSymlinksInPath().path })
        cache = cache.filter { alivePaths.contains($0.key) }

        logger.debug("Scanned \(files.count, privacy: .public) rollout files, cache hits \(cacheHits, privacy: .public)")
        // recentRolloutFiles 已按 mtime 降序，先出现的是当前这份。
        return currentRollouts(summaries)
    }

    /// 增量扫描 FSEvents 命中的路径:只重读变更的 rollout 文件;目录级事件或空缓存时回退 full scan
    public func scanChangedPaths(_ changedPaths: [String]) -> [SessionSummary] {
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
            loggedDroppedRollouts.removeAll()
            logger.info("Codex sessions root missing during incremental scan: \(self.sessionsRoot.path, privacy: .public)")
            return []
        }

        var rolloutPaths = Set<String>()
        var requiresFullScan = false

        for path in changedPaths {
            let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
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
            let url = URL(filePath: path)
            // 子线程文件更新不能再插回一条待办。
            if isChildThreadRollout(at: url) {
                if cache.removeValue(forKey: path) != nil {
                    logger.info("Codex 子线程移出待办: \(url.lastPathComponent, privacy: .public)")
                }
                continue
            }
            if updateCachedRollout(at: url, fileManager: fileManager) {
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

        // 先丢掉子线程再截断。否则一串新的 subagent rollout 会占满最近窗口，父对话进不了列表。
        var kept: [(url: URL, modifiedAt: Date)] = []
        kept.reserveCapacity(min(maxFiles, files.count))
        var skipped = 0
        for file in files.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            if isChildThreadRollout(at: file.url) {
                skipped += 1
                continue
            }
            kept.append(file)
            if kept.count == maxFiles { break }
        }
        if skipped > 0, skipped != lastLoggedSkippedChildThreads {
            logger.info("Codex 子线程不单独进入待办: skipped=\(skipped, privacy: .public)")
            lastLoggedSkippedChildThreads = skipped
        }
        return kept
    }

    /// `thread_source` 在 `base_instructions` 之前。subagent / guardian_review 属于父对话。
    private func isChildThreadRollout(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 2048) else { return false }
        let marker = Data("\"base_instructions\"".utf8)
        let head = prefix.range(of: marker).map { prefix.prefix(upTo: $0.lowerBound) } ?? prefix
        for value in ["subagent", "guardian_review"] {
            if head.range(of: Data("\"thread_source\":\"\(value)\"".utf8)) != nil
                || head.range(of: Data("\"thread_source\": \"\(value)\"".utf8)) != nil {
                return true
            }
        }
        return false
    }

    private func updateCachedRollout(at url: URL, fileManager: FileManager) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else {
                cache.removeValue(forKey: path)
                return false
            }
            if let entry = cache[path], entry.modifiedAt == modifiedAt {
                return false
            }

            cache[path] = try parseRollout(at: url, modifiedAt: modifiedAt)
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

    private func cachedSummaries() -> [SessionSummary] {
        let newestFirst = cache.values
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map(\.summary)
        return Array(currentRollouts(newestFirst).prefix(maxFiles))
    }

    /// Codex 续写文件名是 `rollout-…-<threadId>_<childId>.jsonl`，但 session_meta.id 仍是父线程。
    /// 同一 id 只保留修改时间最新的一份。否则已结束的父文件进待办、续写进运行中，
    /// 续写每追加一段都改 mtime，新待办判定会把这一次旧完成再报一遍。
    /// 调用方必须按 modifiedAt 降序传入；先出现的视为当前 rollout。
    private func currentRollouts(_ summariesNewestFirst: [SessionSummary]) -> [SessionSummary] {
        var seen = Set<String>()
        var kept: [SessionSummary] = []
        kept.reserveCapacity(summariesNewestFirst.count)
        var dropped: Set<String> = []
        for summary in summariesNewestFirst {
            guard seen.insert(summary.id).inserted else {
                dropped.insert(summary.filePath)
                continue
            }
            kept.append(summary)
        }
        // 同一旧文件会在每次续写追加时再次落选，只在第一次丢弃时记日志。
        for path in dropped.subtracting(loggedDroppedRollouts) {
            logger.info("丢弃同一会话的旧 rollout: drop=\(path, privacy: .public)")
        }
        loggedDroppedRollouts = dropped
        return kept
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

    /// 首次分块恢复全部状态，文件追加时从已提交偏移继续，截断或替换则重新恢复。
    private func parseRollout(at url: URL, modifiedAt: Date) throws -> CachedEntry {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        let head = parseHead(handle: handle, decoder: decoder, url: url)
        let size = try handle.seekToEnd()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let previous = cache[url.resolvingSymlinksInPath().path]
        // rollout 正常只追加；同长改写、缩短或 inode 变化时不能复用旧问题。
        let canResume = previous.map {
            fileNumber != nil && $0.fileNumber == fileNumber && size > $0.fileSize
        } ?? false
        var state = CodexRolloutState()
        if canResume, let previous { state = previous.state }
        let visible = try state.read(handle: handle, size: size, modifiedAt: modifiedAt, parseDate: parseISO8601)
        logger.debug("Parsed rollout: resume=\(canResume), bytes=\(size), pendingQuestions=\(visible.unansweredQuestions.count)")

        // 源原生 id 保持原值;provider 固定 codex,复合键由 SessionSummary.id 计算
        let summary = SessionSummary(
            provider: .codex,
            // 首行缺 session_meta 或解析失败时,退化为文件名(去扩展名)作为稳定 ID
            sessionID: head.sessionID ?? url.deletingPathExtension().lastPathComponent,
            filePath: url.resolvingSymlinksInPath().path,
            cwd: head.cwd,
            startedAt: head.startedAt,
            modifiedAt: modifiedAt,
            lifecycleState: visible.lifecycleState,
            taskCompletedAt: visible.taskCompletedAt,
            lastAgentMessage: visible.lastAgentMessage,
            firstPrompt: head.firstPrompt, // head 扫描出的首个 user_message(清洗截断后)
            pendingQuestion: visible.unansweredQuestions.first?.title,
            pendingRequestID: visible.pendingRequestID
        )
        return CachedEntry(modifiedAt: modifiedAt, summary: summary, fileNumber: fileNumber, fileSize: size, state: state)
    }

    /// 读文件头 headByteLimit 字节:第 0 行取 session_meta(id/cwd/startedAt),
    /// 再逐行扫描缓冲区内所有完整行,取首个 event_msg/user_message 作为真实用户提示词。
    private func parseHead(handle: FileHandle, decoder: JSONDecoder, url: URL) -> HeadInfo {
        guard let raw = try? handle.read(upToCount: headByteLimit), !raw.isEmpty else {
            logger.warning("Failed to read rollout head: \(url.path, privacy: .public)")
            return HeadInfo()
        }

        var info = HeadInfo()

        // —— 第 0 行:session_meta(格式稳定在文件首行),取 id/cwd/startedAt ——
        // 截取第一个换行前的内容作为首行;无换行时(无结尾换行的单行小文件)整段尝试解析
        let firstLine: Data
        if let newline = raw.firstIndex(of: UInt8(ascii: "\n")) {
            firstLine = Data(raw.prefix(upTo: newline))
        } else {
            firstLine = raw
        }
        if let line = try? decoder.decode(RolloutLine.self, from: firstLine),
           line.type == "session_meta",
           let payload = line.payload {
            info.sessionID = payload.id ?? payload.sessionId // 真实数据两者并存,优先 id
            info.cwd = payload.cwd
            info.startedAt = payload.timestamp.flatMap { parseISO8601($0) } // payload.timestamp 为会话启动时间
        } else {
            // 首行不是 session_meta(或超出 headByteLimit 被截断),session 三元组置 nil,由调用方 fallback
            logger.warning("Rollout head is not a valid session_meta: \(url.path, privacy: .public)")
        }

        // —— 首个用户提示词 —— 真提示词是缓冲区里首个 event_msg/user_message
        // (response_item 的 role==user 是注入的 AGENTS.md/环境上下文,会被下面的 type 判定天然跳过)。
        // 只保留最后一个换行前的「完整行」,丢弃 256KB 边界可能截断的残行(否则整段 UTF-8 解码可能失败)。
        if let lastNewline = raw.lastIndex(of: UInt8(ascii: "\n")),
           let text = String(data: Data(raw.prefix(upTo: lastNewline)), encoding: .utf8) {
            for candidate in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // 子串预筛:绝大多数行不是 user_message,先用包含判断跳过,避免逐行 JSON 解码开销(与流式状态解析一致)
                guard candidate.contains("\"user_message\"") else { continue }
                guard let parsed = try? decoder.decode(RolloutLine.self, from: Data(candidate.utf8)),
                      parsed.type == "event_msg",
                      parsed.payload?.type == "user_message",
                      let message = parsed.payload?.message else { continue }
                // 命中首个真实用户提示词,清洗后写入并停止扫描
                info.firstPrompt = sanitizeFirstPrompt(message)
                break
            }
        }

        // 项目规范:记录是否提取到 firstPrompt,便于诊断「窗口不够大/格式变化」导致的漏取
        logger.debug(
            "Parsed rollout head \(url.path, privacy: .public): firstPrompt \(info.firstPrompt == nil ? "missing" : "captured", privacy: .public)"
        )

        return info
    }

    // MARK: - 首提示词清洗

    /// 首提示词截断上限(字符数):user_message 可能是几 KB 的终端粘贴(含 ASCII art/多行),
    /// 全文存入 mtime 缓存会把内存撑爆,故只保留首个非空行并截断到此长度。
    private static let firstPromptMaxLength = 200

    /// 清洗 user_message.message:取首个非空行 → trim 首尾空白/换行 → 超长按字符截断并加省略号。
    /// 返回 nil 表示清洗后为空(整段皆空白/换行),调用方视为未捕获到提示词。
    private func sanitizeFirstPrompt(_ message: String) -> String? {
        // 终端粘贴常以空行或分隔线开头,首个 trim 后仍有内容的行才承载用户意图;
        // .lazy 保证找到即停,不为后续每一行都分配 trim 结果
        let firstNonEmptyLine = message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let line = firstNonEmptyLine else { return nil }

        // 超长则按字符(grapheme cluster)截断并追加省略号,控制单条缓存体积
        guard line.count > Self.firstPromptMaxLength else { return line }
        return "\(line.prefix(Self.firstPromptMaxLength))…"
    }

    // MARK: - 时间戳解析

    /// 解析 rollout ISO8601 时间戳:先按带小数秒解析(真实数据为毫秒精度),失败再按整秒兜底
    private func parseISO8601(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}
