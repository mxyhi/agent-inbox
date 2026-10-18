import Darwin
import Foundation
import OSLog

/// 被动读取 DSH 日志；不启动 harness、不打开写会话、不依赖可过期的 projection cache。
public actor DshSessionMonitor {
    public nonisolated static var defaultSessionsRoot: URL {
        let configured = ProcessInfo.processInfo.environment["DSH_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let home = configured.flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".dsh")
        return home.appending(path: "sessions")
    }

    public nonisolated let sessionsRoot: URL
    private let maxFiles: Int
    private let logger = Logger(subsystem: "agent-inbox", category: "DshSessionMonitor")
    private var cache: [String: CachedEntry] = [:]
    private var rejectedFiles: [String: LogFile] = [:]
    private var unreadablePaths: Set<String> = []
    /// 供性能回归和只读基准使用；统计本次扫描真正解析的明文字节，缓存命中必须为零。
    private(set) var lastDecodedBytes = 0

    private struct LogFile: Equatable {
        let url: URL
        let modifiedAt: Date
        let size: Int
        let inode: UInt64
    }

    private struct CachedEntry {
        let file: LogFile
        let parsed: DshSessionLog
        let offset: UInt64
        let checkpoint: Data
    }

    public init(sessionsRoot: URL = DshSessionMonitor.defaultSessionsRoot, maxFiles: Int = 80) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.maxFiles = max(1, maxFiles)
    }

    public func scan() -> [SessionSummary] {
        lastDecodedBytes = 0
        let files = logFiles().sorted { $0.modifiedAt > $1.modifiedAt }
        // 静默运行的旧会话不能被最近文件限额挤掉；锁只用于核实宿主，不表示工作状态。
        let livePaths = Set(files.filter { Self.hasWriter($0.url) }.map(\.url.path))
        var retained: Set<String> = []
        var rootCount = 0
        var reads = 0
        for file in files {
            guard rootCount < maxFiles || livePaths.contains(file.url.path) else { continue }
            if update(file) { reads += 1 }
            retained.insert(file.url.path)
            // 子会话不占主会话的历史窗口，避免密集派工把父会话挤出列表。
            if cache[file.url.path]?.parsed.isChild == false { rootCount += 1 }
        }
        cache = cache.filter { retained.contains($0.key) }
        rejectedFiles = rejectedFiles.filter { retained.contains($0.key) }
        unreadablePaths.formIntersection(retained)
        let liveIDs = Set(cache.values.filter { livePaths.contains($0.file.url.path) }.map(\.parsed.sessionID))
        logger.debug("DSH scan: files=\(retained.count, privacy: .public), reads=\(reads, privacy: .public), decoded_bytes=\(self.lastDecodedBytes, privacy: .public)")
        return summaries(liveIDs: liveIDs)
    }

    public func scanChangedPaths(_ paths: [String]) -> [SessionSummary] {
        lastDecodedBytes = 0
        let root = sessionsRoot.path
        let relevant = paths.map { URL(filePath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            .filter { $0 == root || $0.hasPrefix(root + "/") || root.hasPrefix($0 + "/") }
        guard !relevant.isEmpty else { return summaries() }
        guard !cache.isEmpty else { return scan() }
        for path in relevant {
            let url = URL(filePath: path)
            if isLog(url) {
                // 原生格式切换时只保留优先级最高的日志。
                let candidates = ["session.v4.jsonl.zstd", "session.v4.jsonl"]
                    .map { url.deletingLastPathComponent().appending(path: $0) }
                let preferred = candidates.compactMap { fileInfo($0) }.first
                for candidate in candidates where candidate != preferred?.url {
                    cache.removeValue(forKey: candidate.path)
                    rejectedFiles.removeValue(forKey: candidate.path)
                    unreadablePaths.remove(candidate.path)
                }
                if let preferred { _ = update(preferred) }
            } else if url.lastPathComponent != "session.lock" {
                // 目录创建、删除、重命名和合并事件都需要重建发现集合。
                return scan()
            }
        }
        return summaries()
    }

    @discardableResult
    private func update(_ file: LogFile) -> Bool {
        // 损坏或超限日志在实际改变前不重复解压；保留旧断点仅用于恢复，不再展示旧状态。
        if rejectedFiles[file.url.path] == file { return false }
        if let cached = cache[file.url.path], cached.file.modifiedAt == file.modifiedAt,
           cached.file.size == file.size, cached.file.inode == file.inode,
           !unreadablePaths.contains(file.url.path) {
            return false
        }
        do {
            var offset: UInt64 = 0
            var initial = DshSessionLog()
            if let previous = cache[file.url.path], previous.file.inode == file.inode,
               file.size > previous.file.size, previous.offset > 0,
               try checkpoint(at: file.url, offset: previous.offset) == previous.checkpoint {
                offset = previous.offset
                initial = previous.parsed
            }
            let result = try DshSessionLog.read(at: file.url, from: offset, initial: initial)
            lastDecodedBytes += result.decodedBytes
            guard let current = fileInfo(file.url), current.size == file.size, current.modifiedAt == file.modifiedAt else {
                // 读到中途的新追加不允许沿用旧完成态；下一次 FSEvent 或兜底扫描重试。
                unreadablePaths.insert(file.url.path)
                return true
            }
            cache[file.url.path] = CachedEntry(
                file: file, parsed: result.log, offset: result.offset,
                checkpoint: try checkpoint(at: file.url, offset: result.offset)
            )
            unreadablePaths.remove(file.url.path)
            rejectedFiles.removeValue(forKey: file.url.path)
        } catch {
            unreadablePaths.insert(file.url.path)
            rejectedFiles[file.url.path] = file
            logger.warning("DSH log read failed: path=\(file.url.path, privacy: .private), error=\(String(describing: error), privacy: .public)")
        }
        return true
    }

    private func summaries(liveIDs: Set<String>? = nil) -> [SessionSummary] {
        let entries = cache.values.filter { !unreadablePaths.contains($0.file.url.path) }
        let liveIDs = liveIDs ?? Set(entries.filter { Self.hasWriter($0.file.url) }.map(\.parsed.sessionID))
        let workingChildren = Set(entries.filter {
            $0.parsed.isChild && liveIDs.contains($0.parsed.sessionID) && $0.parsed.lifecycle == .running
        }.map(\.parsed.sessionID))
        return entries.filter { !$0.parsed.isChild }.map { entry in
            let parsed = entry.parsed
            let backgroundCount = parsed.children.intersection(workingChildren).count
            let verified = liveIDs.contains(parsed.sessionID)
            let state: TurnLifecycleState
            if parsed.pendingRequestID != nil { state = .waitingForUser }
            else if backgroundCount > 0 { state = .running }
            else { state = parsed.lifecycle }
            return SessionSummary(
                provider: .dsh,
                sessionID: parsed.sessionID,
                filePath: entry.file.url.path,
                cwd: parsed.cwd,
                startedAt: parsed.startedAt,
                modifiedAt: entry.file.modifiedAt,
                lifecycleState: state,
                taskCompletedAt: state == .completed ? parsed.completedAt : nil,
                lastAgentMessage: parsed.lastAgentMessage,
                firstPrompt: parsed.firstPrompt,
                pendingQuestion: parsed.pendingQuestion,
                pendingRequestID: parsed.pendingRequestID,
                runtimeVerified: verified || backgroundCount > 0,
                backgroundTaskCount: backgroundCount
            )
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func isLog(_ url: URL) -> Bool {
        ["session.v4.jsonl", "session.v4.jsonl.zstd"].contains(url.lastPathComponent)
            && url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path == sessionsRoot.path
    }

    private func fileInfo(_ url: URL) -> LogFile? {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int,
              let inode = attributes[.systemFileNumber] as? UInt64 else { return nil }
        return LogFile(url: url, modifiedAt: modifiedAt, size: size, inode: inode)
    }

    /// 小断点校验阻止截断、原地重写或替换后误走追加路径；不持久化对话内容。
    private func checkpoint(at url: URL, offset: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = min(256, Int(offset))
        var data = try handle.read(upToCount: length) ?? Data()
        try handle.seek(toOffset: offset - UInt64(length))
        data.append(try handle.read(upToCount: length) ?? Data())
        return data
    }

    private func logFiles() -> [LogFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsRoot.path) else { return [] }
        do {
            var result: [LogFile] = []
            let projects = try fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let sessions = try fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                for session in sessions where (try? session.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // DSH 默认使用压缩版；同时存在时遵循该优先级，避免同一会话重复展示。
                    for name in ["session.v4.jsonl.zstd", "session.v4.jsonl"] {
                        if let file = fileInfo(session.appending(path: name)) {
                            result.append(file)
                            break
                        }
                    }
                }
            }
            return result
        } catch {
            logger.warning("DSH enumeration failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private static func hasWriter(_ url: URL) -> Bool {
        // DSH 通过 flock 独占这个空文件。只读打开并尝试共享锁；从不创建或改写锁文件。
        let descriptor = open(url.deletingLastPathComponent().appending(path: "session.lock").path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
