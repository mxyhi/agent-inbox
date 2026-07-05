import CoreServices
import Foundation
import OSLog

/// 被动监听 Codex sessions 目录的 FSEvents 包装器。
/// 只负责把文件系统变更路径交给上层;状态真值仍由 rollout JSONL 解析得到。
final class CodexSessionsWatcher {
    private let root: URL
    private let queue = DispatchQueue(label: "m-todo.codex-sessions-fsevents")
    private let onChange: @Sendable ([String]) -> Void
    private let logger = Logger(subsystem: "m-todo", category: "CodexSessionsWatcher")
    private var stream: FSEventStreamRef?

    init(root: URL, onChange: @escaping @Sendable ([String]) -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            logger.info("Codex sessions root missing, FSEvents watcher not started: \(self.root.path, privacy: .public)")
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

        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else {
            logger.error("Failed to create FSEvents stream for \(self.root.path, privacy: .public)")
            return
        }

        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, queue)
        if FSEventStreamStart(createdStream) {
            logger.info("FSEvents watcher started: \(self.root.path, privacy: .public)")
        } else {
            logger.error("Failed to start FSEvents stream for \(self.root.path, privacy: .public)")
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
        let watcher = Unmanaged<CodexSessionsWatcher>.fromOpaque(info).takeUnretainedValue()
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
