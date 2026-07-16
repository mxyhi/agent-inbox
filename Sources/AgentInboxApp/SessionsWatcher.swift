import CoreServices
import Foundation
import OSLog

/// 多根目录 FSEvents 包装器:被动监听 Codex/Grok 会话路径变更。
/// 只上报变更路径;状态真值仍由各 SessionMonitor 解析。
final class SessionsWatcher {
    private let roots: [URL]
    private let queue = DispatchQueue(label: "agent-inbox.sessions-fsevents")
    private let onChange: @Sendable ([String]) -> Void
    private let logger = Logger(subsystem: "agent-inbox", category: "SessionsWatcher")
    private var stream: FSEventStreamRef?

    init(roots: [URL], onChange: @escaping @Sendable ([String]) -> Void) {
        // 去重标准化路径,避免 ~/.grok 与子路径重复注册
        var seen = Set<String>()
        var unique: [URL] = []
        for root in roots {
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            unique.append(root.standardizedFileURL)
        }
        self.roots = unique
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        let existing = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            logger.info("No session watch roots exist; FSEvents watcher not started")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        let pathList = existing.map(\.path) as CFArray
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            pathList,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else {
            logger.error("Failed to create multi-root FSEvents stream")
            return
        }

        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, queue)
        if FSEventStreamStart(createdStream) {
            logger.info(
                "FSEvents watcher started for \(existing.count, privacy: .public) roots: \(existing.map(\.path).joined(separator: ", "), privacy: .public)"
            )
        } else {
            logger.error("Failed to start multi-root FSEvents stream")
            stop()
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        logger.info("FSEvents watcher stopped")
    }

    private func emit(paths: [String]) {
        guard !paths.isEmpty else { return }
        onChange(paths)
    }

    private static let handleEvents: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<SessionsWatcher>.fromOpaque(info).takeUnretainedValue()
        let pathArray = unsafeBitCast(eventPaths, to: NSArray.self)
        var paths: [String] = []
        paths.reserveCapacity(eventCount)

        for case let path as String in pathArray {
            paths.append(path)
        }
        watcher.emit(paths: paths)
    }

    deinit {
        stop()
    }
}
