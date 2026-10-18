import Darwin
import Foundation

/// DSH v4 原生日志归并；完成时间来自 turn/end，不能用投影缓存的写入时间代替。
struct DshSessionLog: Sendable {
    var sessionID = ""
    var cwd: String?
    var startedAt: Date?
    var lifecycle: TurnLifecycleState = .unknown
    var completedAt: Date?
    var firstPrompt: String?
    var lastAgentMessage: String?
    var isChild = false
    var children: Set<String> = []
    private(set) var pendingQuestion: String?
    private(set) var pendingRequestID: String?
    private var headerIsChild = false
    private var awaitingSeed = false

    private static let observedTypes: Set<String> = [
        "turn/start", "turn/end", "user/message", "assistant/message", "tool/call", "tool/result",
        "tool/ptc-dispatch", "subagent/descriptor", "subagent/catalog", "session/end-seed"
    ]
    private static let typePrefix = Data("{\"type\":\"".utf8)

    mutating func apply(_ line: Data) throws {
        // DSH 的 JSON.stringify 把 type 放在首字段。无关事件及普通工具输出无需分配 JSON 对象；
        // 非标准字段顺序仍走完整解析，避免把格式差异当成丢弃依据。
        if !sessionID.isEmpty, line.starts(with: Self.typePrefix),
           let end = line.dropFirst(Self.typePrefix.count).prefix(80).firstIndex(of: 34) {
            let type = String(decoding: line[Self.typePrefix.count..<end], as: UTF8.self)
            if !type.contains("\\"),
               !Self.observedTypes.contains(type) || (type == "tool/result" && pendingRequestID == nil) { return }
        }
        guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = record["type"] as? String else {
            throw ReadError.invalidRecord
        }
        if sessionID.isEmpty {
            guard type == "session", record["version"] as? Int == 4,
                  let id = record["id"] as? String, !id.isEmpty else {
                throw ReadError.unsupportedHeader
            }
            sessionID = id
            cwd = record["cwd"] as? String
            startedAt = Self.date(record["createdAt"])
            headerIsChild = (record["delegationDepth"] as? Int ?? 0) > 0 || record["origin"] as? String == "subagent"
            isChild = headerIsChild
            awaitingSeed = record["isSeeded"] as? Bool == true
            return
        }

        guard record["seq"] as? Int != nil else { throw ReadError.invalidRecord }
        let data = record["data"] as? [String: Any] ?? [:]
        let timestamp = Self.date(record["time"])
        switch type {
        case "session/end-seed":
            if data["inherited"] as? Bool == true {
                // 最后一个 inherited marker 之前都是父历史，不能产生新会话的完成或待回复。
                lifecycle = .unknown
                completedAt = nil
                firstPrompt = nil
                lastAgentMessage = nil
                children.removeAll()
                isChild = headerIsChild
                awaitingSeed = false
                clearQuestion()
            }
        case "turn/start":
            lifecycle = .running
            completedAt = nil
            lastAgentMessage = nil
        case "turn/end":
            let reason = data["reason"] as? [String: Any]
            if reason?["kind"] as? String == "completed", let timestamp {
                lifecycle = .completed
                completedAt = timestamp
            } else {
                lifecycle = .aborted
                completedAt = nil
            }
        case "user/message":
            let source = data["source"] as? [String: Any]
            if source?["kind"] as? String == "user", firstPrompt == nil {
                firstPrompt = Self.text(data["content"])?
                    .split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) }
            }
            if source?["kind"] as? String == "user-question-reply",
               source?["callId"] as? String == pendingRequestID {
                clearQuestion()
            }
        case "assistant/message":
            let message = data["message"] as? [String: Any]
            if let text = Self.text(message?["content"]) {
                lastAgentMessage = String(text.prefix(4_000))
            }
        case "tool/call":
            guard data["name"] as? String == "ask_user_question" else { return }
            setQuestion(arguments: data["arguments"], id: data["callId"] as? String)
        case "tool/result":
            let message = data["message"] as? [String: Any]
            guard let id = message?["toolCallId"] as? String, id == pendingRequestID else { return }
            let error = data["error"] as? [String: Any]
            // 定时提问可以在工具返回后继续等待；恢复时的未知结果也不代表用户已回答。
            if !Self.isPending(message?["content"]), error?["code"] as? String != "TOOL_OUTCOME_UNKNOWN" {
                clearQuestion()
            }
        case "tool/ptc-dispatch":
            guard data["name"] as? String == "ask_user_question",
                  data["isError"] as? Bool != true, Self.isPending(data["content"]) else { return }
            setQuestion(arguments: data["arguments"], id: data["subCallId"] as? String)
        case "subagent/descriptor":
            isChild = true
        case "subagent/catalog":
            if let id = data["childId"] as? String { children.insert(id) }
        default:
            break
        }
    }

    private mutating func setQuestion(arguments: Any?, id: String?) {
        var arguments = arguments
        if let string = arguments as? String {
            arguments = try? JSONSerialization.jsonObject(with: Data(string.utf8))
        }
        guard let arguments = arguments as? [String: Any],
              let questions = arguments["questions"] as? [[String: Any]],
              let id, !id.isEmpty else { return }
        let text = questions.compactMap { $0["question"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        pendingQuestion = String(text.prefix(4_000))
        pendingRequestID = id
    }

    private mutating func clearQuestion() {
        pendingQuestion = nil
        pendingRequestID = nil
    }

    private static func isPending(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]],
              let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return false
        }
        return value["pending"] as? Bool == true
    }

    private static func text(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func date(_ value: Any?) -> Date? {
        guard let milliseconds = value as? Double, milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    enum ReadError: Error {
        case invalidRecord, unsupportedHeader, oversizedLog, decompressorUnavailable, decompressionFailed
    }

    /// 有界流式读取；只接受换行结束的记录，忽略正在写入的最后半行。
    struct ReadResult {
        let log: DshSessionLog
        let offset: UInt64
        let decodedBytes: Int
    }

    static func read(at url: URL, from offset: UInt64 = 0, initial: DshSessionLog = DshSessionLog()) throws -> ReadResult {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        try source.seek(toOffset: offset)
        let input: FileHandle
        var process: Process?
        var termination: DispatchSemaphore?
        var waitedForExit = false
        var timeout: DispatchWorkItem?
        if url.pathExtension == "zstd" {
            let decoder = try decompressor(for: url)
            let pipe = Pipe()
            decoder.standardOutput = pipe
            decoder.standardError = FileHandle.nullDevice
            decoder.standardInput = source
            let finished = DispatchSemaphore(value: 0)
            decoder.terminationHandler = { _ in finished.signal() }
            try decoder.run()
            termination = finished
            // 关闭父进程的写端，子进程失败或退出后读取方才能观察到 EOF。
            try pipe.fileHandleForWriting.close()
            // 解压进程仅持有只读输入；到期强制结束，避免忽略 SIGTERM 的程序占住扫描。
            let deadline = DispatchWorkItem { if decoder.isRunning { kill(decoder.processIdentifier, SIGKILL) } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: deadline)
            timeout = deadline
            process = decoder
            input = pipe.fileHandleForReading
        } else {
            input = source
        }
        defer {
            timeout?.cancel()
            try? input.close()
            if let process, !waitedForExit {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                termination?.wait()
            }
        }

        var parsed = initial
        var pending = Data()
        var total = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            total += chunk.count
            guard total <= 128 * 1024 * 1024 else { throw ReadError.oversizedLog }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 10) {
                if newline > start {
                    try autoreleasepool { try parsed.apply(Data(pending[start..<newline])) }
                }
                start = pending.index(after: newline)
            }
            if start > pending.startIndex { pending = Data(pending[start...]) }
            guard pending.count <= 16 * 1024 * 1024 else { throw ReadError.oversizedLog }
        }
        if let process {
            // Foundation 的 waitUntilExit 会轮询 run loop；退出通知避免每份小日志的固定等待成本。
            termination?.wait()
            waitedForExit = true
            guard process.terminationStatus == 0 else { throw ReadError.decompressionFailed }
        }
        guard !parsed.sessionID.isEmpty, !parsed.awaitingSeed else { throw ReadError.unsupportedHeader }
        // 压缩输入只有成功解完整帧才建立断点；明文半行必须留到下次从行首重读。
        let consumed = url.pathExtension == "zstd" ? try source.offset() : offset + UInt64(total - pending.count)
        return ReadResult(log: parsed, offset: consumed, decodedBytes: total)
    }

    private static func decompressor(for url: URL) throws -> Process {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home.appending(path: ".local/bin").path,
               home.appending(path: "Library/pnpm").path, home.appending(path: ".volta/bin").path]
        for name in ["zstd", "node"] {
            for directory in directories where directory.hasPrefix("/") {
                let executable = URL(filePath: directory).appending(path: name)
                guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
                let process = Process()
                process.executableURL = executable
                if name == "zstd" {
                    process.arguments = ["-dcq"]
                } else {
                    // DSH 本身需要支持 Zstandard 的 Node；参数独立传递，不拼接 shell 命令。
                    let script = """
                    const {pipeline} = require('node:stream');
                    const {createZstdDecompress} = require('node:zlib');
                    pipeline(process.stdin, createZstdDecompress(), process.stdout,
                      error => { if (error) process.exitCode = 1; });
                    """
                    process.arguments = ["-e", script]
                }
                return process
            }
        }
        throw ReadError.decompressorUnavailable
    }
}
