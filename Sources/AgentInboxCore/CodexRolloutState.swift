import Foundation
import OSLog

/// 顺序归并 rollout 事件；偏移只提交到完整行，启动恢复与后续追加共用同一路径。
struct CodexRolloutState {
    private struct Event: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let last_agent_message: String?
        let item: Item?
    }

    private struct Item: Decodable {
        let type: String?
        let delivery: String?
        let questions: [Question]?
        let content: [Content]?
    }

    private struct Question: Decodable { let title: String? }
    private struct Content: Decodable { let text: String? }

    private static let logger = Logger(subsystem: "agent-inbox", category: "CodexRolloutState")
    private(set) var offset: UInt64 = 0
    private var lifecycle: TurnLifecycleState = .running
    private(set) var taskCompletedAt: Date?
    private(set) var lastAgentMessage: String?
    private(set) var unansweredQuestions: [String] = []

    // 待回答是展示覆盖层，不能覆盖底层完成态，否则回答后无法恢复。
    var lifecycleState: TurnLifecycleState {
        unansweredQuestions.isEmpty ? lifecycle : .waitingForUser
    }

    /// 固定大小读取块，不限制历史长度；额外内存仅为当前尚未结束的一行。
    /// EOF 没有换行但 JSON 完整时可预览，状态与偏移留在行首，追加后再正式提交。
    mutating func read(
        handle: FileHandle,
        size: UInt64,
        modifiedAt: Date,
        parseDate: (String) -> Date?
    ) throws -> Self {
        try handle.seek(toOffset: offset)
        let startOffset = offset
        var readOffset = offset
        var pending = Data()
        let decoder = JSONDecoder()
        while readOffset < size {
            let count = Int(min(64 * 1024, size - readOffset))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            readOffset += UInt64(chunk.count)
            let scanStart = pending.endIndex
            pending.append(chunk)
            // 直接遍历只读字节视图，避免冷启动时对数百 MB 执行 Foundation Data 逐字节访问。
            let consumed = pending.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var lineStart = 0
                for index in scanStart..<bytes.count where bytes[index] == 0x0A {
                    consume(Data(bytes[lineStart..<index]), decoder: decoder, modifiedAt: modifiedAt, parseDate: parseDate)
                    offset += UInt64(index - lineStart + 1)
                    lineStart = index + 1
                }
                return lineStart
            }
            if consumed > 0 {
                pending = Data(pending[consumed...])
            }
        }

        var preview = self
        if !pending.isEmpty {
            preview.consume(pending, decoder: decoder, modifiedAt: modifiedAt, parseDate: parseDate)
        }
        Self.logger.debug("Rollout read: bytes=\(readOffset - startOffset), pendingQuestions=\(preview.unansweredQuestions.count)")
        return preview
    }

    /// 只归并 event_msg，工具结果或注入内容中的同名字段不能冒充状态事件。
    private mutating func consume(
        _ data: Data,
        decoder: JSONDecoder,
        modifiedAt: Date,
        parseDate: (String) -> Date?
    ) {
        // 在字节层筛选 ASCII 协议标记，避免为大段工具输出执行 Unicode 子串匹配。
        guard data.range(of: Self.eventEnvelopeMarker) != nil,
              Self.eventMarkers.contains(where: { data.range(of: $0) != nil }),
              let event = try? decoder.decode(Event.self, from: data),
              event.type == "event_msg", let payload = event.payload else { return }

        switch payload.type {
        case "task_started", "turn_started":
            lifecycle = .running
            taskCompletedAt = nil
            lastAgentMessage = nil
        case "exec_approval_request", "apply_patch_approval_request", "request_permissions", "request_user_input", "elicitation_request":
            lifecycle = .waitingForUser
        case "task_complete", "turn_complete":
            lifecycle = .completed
            taskCompletedAt = event.timestamp.flatMap(parseDate) ?? modifiedAt
            lastAgentMessage = payload.last_agent_message
        case "turn_aborted", "thread_rolled_back":
            lifecycle = payload.type == "turn_aborted" ? .aborted : .rolledBack
            taskCompletedAt = nil
            lastAgentMessage = nil
            unansweredQuestions.removeAll()
        case "item_completed":
            guard let item = payload.item else { return }
            if item.type == "AgentMessage", item.delivery == "async" {
                for title in item.questions?.compactMap(\.title) ?? []
                    where !title.isEmpty && !unansweredQuestions.contains(title) {
                    unansweredQuestions.append(title)
                }
            } else if item.type == "UserMessage" {
                consumeAnswer(item.content?.compactMap(\.text).joined(separator: "\n"))
            }
        default:
            break
        }
    }

    /// 引用回答仅消费对应标题；重复回答不能误清其他问题，普通新输入消费旧问题。
    private mutating func consumeAnswer(_ message: String?) {
        guard let message, !message.isEmpty, !unansweredQuestions.isEmpty else { return }
        if message.hasPrefix("> "), let separator = message.range(of: "\n\n") {
            let title = String(message[message.index(message.startIndex, offsetBy: 2)..<separator.lowerBound])
            unansweredQuestions.removeAll { $0 == title }
        } else {
            unansweredQuestions.removeAll()
        }
    }

    private static let eventEnvelopeMarker = Data("\"event_msg\"".utf8)
    private static let eventMarkers = [
        "task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted",
        "thread_rolled_back", "exec_approval_request", "apply_patch_approval_request",
        "request_permissions", "request_user_input", "elicitation_request", "item_completed"
    ].map { Data("\"\($0)\"".utf8) }
}
