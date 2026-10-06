import Foundation

/// 缓存只复用未变文件的解析结果；任务到期与宿主活性仍在每次刷新时计算。
struct GrokFileStamp: Equatable {
    let inode: UInt64
    let size: UInt64
    let modifiedAt: Date

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        self.inode = inode.uint64Value
        self.size = size.uint64Value
        self.modifiedAt = modifiedAt
    }
}

/// 只在 GrokSessionMonitor actor 内使用。冷启动顺序恢复，后续仅消费新增完整行。
/// 不以 tail 窗口或输出频率推断任务结束；截断/替换/同长重写会重建状态。
private final class GrokJSONLines {
    private var inode: UInt64?
    private var offset: UInt64 = 0
    private var modifiedAt: Date?
    private var pending = Data()
    private var anchor = Data()

    func read(_ url: URL, fromLastTurn: Bool = false, reset: () -> Void, consume: (Data) -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if inode != nil { reset() }
            inode = nil; offset = 0; pending = Data(); anchor = Data(); modifiedAt = nil
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let nextInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let nextModified = attributes[.modificationDate] as? Date
        let size = try handle.seekToEnd()
        if inode == nextInode, size == offset, modifiedAt == nextModified { return }
        var replaced = inode != nextInode || size < offset || (size == offset && nextModified != modifiedAt)
        if !replaced, offset > 0, !anchor.isEmpty {
            try handle.seek(toOffset: offset - UInt64(anchor.count))
            replaced = try handle.read(upToCount: anchor.count) != anchor
        }
        if replaced {
            reset(); offset = 0; pending = Data(); anchor = Data()
            if fromLastTurn { offset = try lastTurnOffset(handle: handle, size: size) }
        }
        inode = nextInode
        try handle.seek(toOffset: offset)
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            anchor.append(chunk)
            anchor = Data(anchor.suffix(256))
            // 长工具结果可占一整行。只查新追加的字节，不能每块都重扫/拷贝整个半行。
            var searchStart = pending.count
            pending.append(chunk)
            var start = pending.startIndex
            while let end = pending[searchStart...].firstIndex(of: 10) {
                // JSON/Foundation 桥接对象逐行释放，峰值不随历史日志总长度增长。
                autoreleasepool { consume(Data(pending[start..<end])) }
                start = end + 1
                searchStart = start
            }
            if start > 0 { pending = Data(pending[start...]) }
        }
        // 某些旧文件没有末尾换行；完整 JSON 可立即消费，半行则留到下次追加。
        if !pending.isEmpty, (try? JSONSerialization.jsonObject(with: pending)) != nil {
            consume(pending)
            pending = Data()
        }
        modifiedAt = nextModified
    }

    private func lastTurnOffset(handle: FileHandle, size: UInt64) throws -> UInt64 {
        // 冷启动只需最近回合，但边界可在任意距离；逐块向前找，不把128KiB当作状态边界。
        var end = size
        var suffix = Data()
        while end > 0 {
            let start = end > 64 * 1024 ? end - 64 * 1024 : 0
            try handle.seek(toOffset: start)
            var block = try handle.read(upToCount: Int(end - start)) ?? Data()
            block.append(suffix)
            let firstNewline = block.firstIndex(of: 10)
            let completeStart = start == 0 ? 0 : (firstNewline.map { $0 + 1 } ?? block.count)
            var lineEnd = block.count
            while lineEnd > completeStart {
                let before = block[..<lineEnd].lastIndex(of: 10)
                let lineStart = before.map { $0 + 1 } ?? completeStart
                let line = block[lineStart..<lineEnd]
                if let text = String(data: line, encoding: .utf8),
                   text.contains("turn_started") || text.contains("turn_ended"),
                   let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let type = object["type"] as? String, type == "turn_started" || type == "turn_ended" {
                    return start + UInt64(lineStart)
                }
                guard let before else { break }
                lineEnd = before
            }
            suffix = Data(block.prefix(firstNewline ?? block.count))
            end = start
        }
        return 0
    }
}

final class GrokRuntimeState {
    private static let updateKey = Data("\"sessionUpdate\"".utf8)
    private static let questionVariant = Data("AskUserQuestion".utf8)

    /// Grok 的 JSONL 判别字段是短 ASCII 字符串；先取字段，避免把巨型工具输出转换为 String。
    /// 不依赖字段顺序或固定前缀长度；非标准转义字段交给完整 decoder 兼容。
    private func updateKind(in line: Data) -> String? {
        guard let key = line.range(of: Self.updateKey) else {
            return (try? decoder.decode(Envelope.self, from: line))?.params?.update?.sessionUpdate
        }
        var index = key.upperBound
        while index < line.endIndex, [9, 10, 13, 32, 58].contains(line[index]) { index += 1 }
        guard index < line.endIndex, line[index] == 34 else { return nil }
        index += 1
        guard let end = line[index...].firstIndex(of: 34) else { return nil }
        return String(data: line[index..<end], encoding: .utf8)
    }
    enum Turn {
        case none
        case started(Date?)
        case ended(Date?, String?)
    }

    struct Request {
        let id: String
        let question: String
        let tool: String
        let at: Date?
    }

    private struct BackgroundTask: Decodable {
        let task_id: String
        let kind: String?
        let status: String?
        let started_at: String?
        let ended_at: String?
        let completed: Bool?
        let output_file: String?
    }

    private struct Event: Decodable {
        let type: String
        let ts: String?
        let outcome: String?
        let tool_name: String?
    }

    private struct Envelope: Decodable {
        struct Params: Decodable { let update: Update? }
        struct Update: Decodable {
            struct Input: Decodable { let variant: String? }
            let sessionUpdate: String
            let tasks: [BackgroundTask]?
            let task_id: String?
            let task_snapshot: BackgroundTask?
            let output_file: String?
            let subagent_id: String?
            let attempt_id: String?
            let status: String?
            let toolCallId: String?
            let rawInput: Input?
        }
        let params: Params?
        let timestamp: String?
    }

    private struct Resources: Decodable {
        struct State: Decodable {
            let scheduler: Scheduler?
            enum CodingKeys: String, CodingKey { case scheduler = "grok_build.Scheduler" }
        }
        let state: State?
    }
    private struct Scheduler: Decodable { let tasks: [Schedule] }

    private var resourcesStamp: GrokFileStamp?
    private var schedules: [Schedule] = []

    private struct Schedule: Decodable {
        let id: String
        let createdAt: String?
        let lastFiredAt: String?
        let expiresAt: String?
        let recurring: Bool?
        let durable: Bool?
    }

    private struct Child: Decodable {
        let status: String?
        let started_at: String?
        let completed_at: String?
        let attempt_id: String?
    }

    private let events = GrokJSONLines()
    private let updates = GrokJSONLines()
    private let decoder = JSONDecoder()
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    private(set) var turn: Turn = .none
    private(set) var lastWorkEndedAt: Date?
    private var permissions: [Request] = []
    private var questions: [String: Request] = [:]
    private var tasks: [String: BackgroundTask] = [:]
    private var children: [String: String] = [:]
    private var deletedSchedules: Set<String> = []

    init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }

    func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }

    func refresh(at directory: URL) throws {
        try events.read(directory.appending(path: "events.jsonl"), fromLastTurn: true, reset: {
            self.turn = .none
            self.permissions.removeAll()
        }, consume: { line in
            guard let text = String(data: line, encoding: .utf8),
                  ["turn_started", "turn_ended", "permission_requested", "permission_resolved"].contains(where: text.contains),
                  let event = try? self.decoder.decode(Event.self, from: line) else { return }
            switch event.type {
            case "turn_started":
                self.turn = .started(self.date(event.ts))
                self.permissions.removeAll()
            case "turn_ended":
                self.turn = .ended(self.date(event.ts), event.outcome)
                self.permissions.removeAll()
            case "permission_requested":
                let tool = event.tool_name ?? "tool"
                self.permissions.append(Request(id: "permission:\(event.ts ?? ""):\(tool)", question: "Grok 等待批准：\(tool)", tool: tool, at: self.date(event.ts)))
            case "permission_resolved":
                if let index = self.permissions.firstIndex(where: { $0.tool == (event.tool_name ?? "tool") }) {
                    self.permissions.remove(at: index)
                }
            default: break
            }
        })
        try updates.read(directory.appending(path: "updates.jsonl"), reset: {
            self.tasks.removeAll(); self.children.removeAll(); self.questions.removeAll(); self.deletedSchedules.removeAll()
            self.lastWorkEndedAt = nil
        }, consume: { line in
            // 文案和大型工具结果不参与状态归并，避免对每个输出块做完整解码。
            guard let kind = self.updateKind(in: line),
                  ["background_tasks", "task_backgrounded", "task_completed", "subagent_spawned", "subagent_finished", "scheduled_task_created", "scheduled_task_deleted", "turn_completed"].contains(kind)
                    || (kind == "tool_call" && line.range(of: Self.questionVariant) != nil)
                    || (["tool_call_update", "user_message_chunk"].contains(kind) && !self.questions.isEmpty),
                  let envelope = try? self.decoder.decode(Envelope.self, from: line),
                  let update = envelope.params?.update else { return }
            if ["task_completed", "subagent_finished", "scheduled_task_deleted"].contains(kind), let ended = self.date(envelope.timestamp) {
                self.lastWorkEndedAt = max(self.lastWorkEndedAt ?? .distantPast, ended)
            }
            switch update.sessionUpdate {
            case "background_tasks":
                self.tasks = Dictionary((update.tasks ?? []).filter { $0.status == "running" }.map { ($0.task_id, $0) }, uniquingKeysWith: { _, latest in latest })
            case "task_backgrounded":
                if let id = update.task_id {
                    self.tasks[id] = BackgroundTask(task_id: id, kind: nil, status: "running", started_at: nil,
                        ended_at: nil, completed: false, output_file: update.output_file)
                }
            case "task_completed":
                if let task = update.task_snapshot { self.tasks.removeValue(forKey: task.task_id) }
            case "subagent_spawned":
                if let id = update.subagent_id { self.children[id] = update.attempt_id ?? "" }
            case "subagent_finished":
                if let id = update.subagent_id, self.children[id] == (update.attempt_id ?? "") { self.children.removeValue(forKey: id) }
            case "scheduled_task_deleted":
                if let id = update.task_id { self.deletedSchedules.insert(id) }
            case "scheduled_task_created":
                if let id = update.task_id { self.deletedSchedules.remove(id) }
            case "tool_call":
                if update.rawInput?.variant == "AskUserQuestion", let id = update.toolCallId {
                    self.questions[id] = Request(id: id, question: "Grok 等待你回答问题", tool: "ask_user_question", at: nil)
                }
            case "tool_call_update":
                if let id = update.toolCallId, ["completed", "failed"].contains(update.status ?? "") { self.questions.removeValue(forKey: id) }
            case "turn_completed", "user_message_chunk": self.questions.removeAll()
            default: break
            }
        })
    }

    func pendingRequest(host: GrokProcessSnapshot) -> Request? {
        // 旧进程的未决权限不得在恢复后凭历史事件重新弹出。
        guard case let .started(at) = turn, (at ?? .distantPast) >= host.startedAt else { return nil }
        return permissions.first(where: { ($0.at ?? .distantPast) >= host.startedAt })
            ?? questions.sorted(by: { $0.key < $1.key }).first?.value
    }

    func backgroundCount(at directory: URL, host: GrokProcessSnapshot, now: Date) throws -> Int {
        let activeTasks = tasks.values.filter { task in
            // 重启后磁盘会残留 running。只接受本进程启动后的任务，或仍持有的任务输出。
            (date(task.started_at) ?? .distantPast) >= host.startedAt
                || task.output_file.map { host.openFiles.contains(URL(filePath: $0).resolvingSymlinksInPath().path) } == true
        }.count
        var activeChildren = 0
        for (id, attempt) in children {
            let file = directory.appending(path: "subagents/\(id)/meta.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let child = try decoder.decode(Child.self, from: Data(contentsOf: file))
            if child.completed_at == nil, !["completed", "failed", "cancelled", "canceled"].contains(child.status ?? ""),
               (date(child.started_at) ?? .distantPast) >= host.startedAt,
               attempt.isEmpty || child.attempt_id == attempt { activeChildren += 1 }
        }
        let resourceURL = directory.appending(path: "resources_state.json")
        let stamp = GrokFileStamp(resourceURL)
        if stamp != resourcesStamp {
            // 其他 resource.state 类型各异，只解码 Scheduler，而非整份异构 state。
            schedules = stamp == nil ? []
                : try decoder.decode(Resources.self, from: Data(contentsOf: resourceURL)).state?.scheduler?.tasks ?? []
            resourcesStamp = stamp
        }
        let activeSchedules = schedules.filter { task in
            !deletedSchedules.contains(task.id)
                && (date(task.expiresAt) ?? .distantPast) > now
                && (task.recurring != false || task.lastFiredAt == nil)
                && (task.durable == true || max(date(task.createdAt) ?? .distantPast, date(task.lastFiredAt) ?? .distantPast) >= host.startedAt)
        }.count
        return activeTasks + activeChildren + activeSchedules
    }
}
