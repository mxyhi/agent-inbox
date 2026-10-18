import Foundation
import OSLog

/// 组合多源会话监控:并行扫描各源,合并为统一摘要列表。
///
/// 主线程零 IO;各源 actor 内各自缓存。增量路径只发给命中的源,
/// 无关源复用摘要，不触发扫描或 CLI 查询。
public actor CompositeSessionMonitor {
    public nonisolated let codex: CodexSessionMonitor
    public nonisolated let grok: GrokSessionMonitor
    public nonisolated let claude: ClaudeSessionMonitor
    public nonisolated let dsh: DshSessionMonitor
    private let logger = Logger(subsystem: "agent-inbox", category: "CompositeSessionMonitor")
    private var cachedSummaries: [AgentProvider: [SessionSummary]] = [:]
    private var refreshTask: Task<[SessionSummary], Never>?
    private var pendingPaths: Set<String> = []
    private var needsFullScan = false

    public init(
        codex: CodexSessionMonitor = CodexSessionMonitor(),
        grok: GrokSessionMonitor = GrokSessionMonitor(),
        claude: ClaudeSessionMonitor = ClaudeSessionMonitor(),
        dsh: DshSessionMonitor = DshSessionMonitor()
    ) {
        self.codex = codex
        self.grok = grok
        self.claude = claude
        self.dsh = dsh
    }

    /// FSEvents 需要监听的根路径(存在才有意义,由 watcher 再过滤)
    public nonisolated var watchRoots: [URL] {
        [
            codex.sessionsRoot,
            grok.sessionsRoot,
            claude.sessionsRoot,
            dsh.sessionsRoot,
            // active_sessions.json 与 sessions 同属 ~/.grok,单独点出文件父目录不够稳时仍扫 sessions;
            // 文件本身变更靠 grok 根附近路径命中;显式加入文件 URL 的父目录
            grok.activeSessionsFile.deletingLastPathComponent()
        ]
    }

    public func scan() async -> [SessionSummary] {
        needsFullScan = true
        return await refresh()
    }

    public func scanChangedPaths(_ paths: [String]) async -> [SessionSummary] {
        pendingPaths.formUnion(paths)
        if cachedSummaries.isEmpty, refreshTask == nil { needsFullScan = true }
        return await refresh()
    }

    private func refresh() async -> [SessionSummary] {
        if let refreshTask { return await refreshTask.value }
        // 扫描期间的事件只合并路径。所有调用方等待同一批结果，避免 actor 重入排出多轮全扫。
        let task = Task { await self.drainRefreshes() }
        refreshTask = task
        return await task.value
    }

    private func drainRefreshes() async -> [SessionSummary] {
        while needsFullScan || !pendingPaths.isEmpty {
            let full = needsFullScan
            let paths = Array(pendingPaths)
            needsFullScan = false
            pendingPaths.removeAll()
            if full { await scanAllSources() }
            else { await scanSources(changedPaths: paths) }
        }
        refreshTask = nil
        return mergedSummaries()
    }

    /// 同一轮内并行扫描各源，跨轮串行归并。
    private func scanAllSources() async {
        async let codexSummaries = codex.scan()
        async let grokSummaries = grok.scan()
        async let claudeSummaries = claude.scan()
        async let dshSummaries = dsh.scan()
        cachedSummaries = await [.codex: codexSummaries, .grok: grokSummaries, .claude: claudeSummaries, .dsh: dshSummaries]
        let merged = mergedSummaries()
        logger.debug(
            "Composite scan merged \(merged.count, privacy: .public) summaries"
        )
    }

    private func scanSources(changedPaths paths: [String]) async {
        let paths = paths.map { URL(filePath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        let codexPaths = matching(paths, roots: [codex.sessionsRoot])
        let grokPaths = matching(paths, roots: [grok.sessionsRoot, grok.activeSessionsFile])
        let claudePaths = matching(paths, roots: [claude.sessionsRoot])
        let dshPaths = matching(paths, roots: [dsh.sessionsRoot])
        guard !codexPaths.isEmpty || !grokPaths.isEmpty || !claudePaths.isEmpty || !dshPaths.isEmpty else {
            return
        }
        // 未命中的源直接复用上次摘要，包括空结果；不能因另一个工具输出而扫描或启动 CLI。
        async let codexSummaries = codexPaths.isEmpty ? cachedSummaries[.codex] ?? [] : codex.scanChangedPaths(codexPaths)
        async let grokSummaries = grokPaths.isEmpty ? cachedSummaries[.grok] ?? [] : grok.scanChangedPaths(grokPaths)
        async let claudeSummaries = claudePaths.isEmpty ? cachedSummaries[.claude] ?? [] : claude.scanChangedPaths(claudePaths)
        async let dshSummaries = dshPaths.isEmpty ? cachedSummaries[.dsh] ?? [] : dsh.scanChangedPaths(dshPaths)
        cachedSummaries = await [.codex: codexSummaries, .grok: grokSummaries, .claude: claudeSummaries, .dsh: dshSummaries]
        let merged = mergedSummaries()
        logger.debug(
            "Composite incremental scan merged \(merged.count, privacy: .public) summaries for \(paths.count, privacy: .public) paths"
        )
    }

    private func mergedSummaries() -> [SessionSummary] {
        AgentProvider.allCases.flatMap { cachedSummaries[$0] ?? [] }
    }

    private func matching(_ paths: [String], roots: [URL]) -> [String] {
        let roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        return paths.filter { path in
            roots.contains { root in path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/") }
        }
    }
}
