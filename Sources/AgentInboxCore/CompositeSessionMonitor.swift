import Foundation
import OSLog

/// 组合多源会话监控:并行扫描 Codex + Grok,合并为统一摘要列表。
///
/// 主线程零 IO;各源 actor 内各自缓存。增量路径把变更路径原样下发,
/// 源内部自行判断是否与己相关。
public actor CompositeSessionMonitor {
    public nonisolated let codex: CodexSessionMonitor
    public nonisolated let grok: GrokSessionMonitor
    private let logger = Logger(subsystem: "agent-inbox", category: "CompositeSessionMonitor")

    public init(
        codex: CodexSessionMonitor = CodexSessionMonitor(),
        grok: GrokSessionMonitor = GrokSessionMonitor()
    ) {
        self.codex = codex
        self.grok = grok
    }

    /// FSEvents 需要监听的根路径(存在才有意义,由 watcher 再过滤)
    public nonisolated var watchRoots: [URL] {
        [
            codex.sessionsRoot,
            grok.sessionsRoot,
            // active_sessions.json 与 sessions 同属 ~/.grok,单独点出文件父目录不够稳时仍扫 sessions;
            // 文件本身变更靠 grok 根附近路径命中;显式加入文件 URL 的父目录
            grok.activeSessionsFile.deletingLastPathComponent()
        ]
    }

    /// 并行全量扫描并合并
    public func scan() async -> [SessionSummary] {
        async let codexSummaries = codex.scan()
        async let grokSummaries = grok.scan()
        let merged = await codexSummaries + grokSummaries
        logger.debug(
            "Composite scan merged \(merged.count, privacy: .public) summaries"
        )
        return merged
    }

    /// 并行增量扫描并合并
    public func scanChangedPaths(_ paths: [String]) async -> [SessionSummary] {
        async let codexSummaries = codex.scanChangedPaths(paths)
        async let grokSummaries = grok.scanChangedPaths(paths)
        let merged = await codexSummaries + grokSummaries
        logger.debug(
            "Composite incremental scan merged \(merged.count, privacy: .public) summaries for \(paths.count, privacy: .public) paths"
        )
        return merged
    }
}
