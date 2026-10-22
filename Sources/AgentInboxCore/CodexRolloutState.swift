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
        let name: String?
        let arguments: String?
        let call_id: String?
    }

    private struct Item: Decodable {
        let type: String?
        let delivery: String?
        let questions: [Question]?
        let content: [Content]?
    }

    private struct Question: Decodable { let title: String? }
    private struct Content: Decodable { let text: String? }
    private struct InputArguments: Decodable {
        struct Question: Decodable { let question: String }
        let questions: [Question]
    }

    struct PendingQuestion {
        let id: String
        let title: String
        var callID: String? = nil
    }

    private static let logger = Logger(subsystem: "agent-inbox", category: "CodexRolloutState")
    private(set) var offset: UInt64 = 0
    private var lifecycle: TurnLifecycleState = .running
    private(set) var taskCompletedAt: Date?
    private(set) var lastAgentMessage: String?
    private(set) var unansweredQuestions: [PendingQuestion] = []
    private var waitingRequestID: String?

    /// 按事件位置识别请求；冷启动、增量读取和普通输出都得到同一个确认标识。
    var pendingRequestID: String? {
        unansweredQuestions.isEmpty
            ? (lifecycle == .waitingForUser ? waitingRequestID : nil)
            : unansweredQuestions.map(\.id).joined(separator: "|")
    }

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
                    // 大型历史回放的桥接对象逐行释放，避免累积成数百MB的分配器峰值。
                    autoreleasepool {
                        consume(Data(bytes[lineStart..<index]), decoder: decoder, modifiedAt: modifiedAt, parseDate: parseDate)
                    }
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

    /// 仅消费结构化事件和白名单工具调用；正文里的协议字段不能冒充状态事件。
    private mutating func consume(
        _ data: Data,
        decoder: JSONDecoder,
        modifiedAt: Date,
        parseDate: (String) -> Date?
    ) {
        // 在字节层筛选 ASCII 协议标记，避免为大段工具输出执行 Unicode 子串匹配。
        let isEvent = data.range(of: Self.eventEnvelopeMarker) != nil
            && Self.eventMarkers.contains(where: { data.range(of: $0) != nil })
        // 工具结果只在有对应待回复时解码，不解码或保留全部历史工具输出。
        let isInputCall = data.range(of: Self.inputCallMarker) != nil
        let isPendingResult = unansweredQuestions.contains { $0.callID != nil }
            && data.range(of: Self.callOutputMarker) != nil
        guard isEvent || isInputCall || isPendingResult,
              let event = try? decoder.decode(Event.self, from: data),
              let payload = event.payload else { return }

        if event.type == "response_item" {
            if payload.type == "function_call", payload.name == "request_user_input",
               let callID = payload.call_id, !callID.isEmpty,
               let arguments = payload.arguments,
               let input = try? decoder.decode(InputArguments.self, from: Data(arguments.utf8)) {
                // 新版不会持久化 RequestUserInput 事件，必须用调用与结果的 call_id 配对。
                let incoming = input.questions.enumerated().compactMap { index, question -> PendingQuestion? in
                    guard !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return PendingQuestion(id: "call:\(callID):\(index)", title: question.question, callID: callID)
                }
                guard !incoming.isEmpty,
                      incoming.map(\.id) != unansweredQuestions.map(\.id) else { return }
                replaceQuestions(incoming)
            } else if payload.type == "function_call_output", let callID = payload.call_id {
                consumeToolResult(callID)
            }
            return
        }
        guard event.type == "event_msg" else { return }

        switch payload.type {
        case "task_started", "turn_started":
            lifecycle = .running
            taskCompletedAt = nil
            lastAgentMessage = nil
        case "exec_approval_request", "apply_patch_approval_request", "request_permissions", "request_user_input", "elicitation_request":
            // 同一会话只有一条待办。新的审批替换尚未回答的问题，避免旧问题继续占着卡片。
            if !unansweredQuestions.isEmpty {
                let previousCount = unansweredQuestions.count
                Self.logger.info(
                    "新的审批请求替换同一会话的旧问题: previous=\(previousCount, privacy: .public)"
                )
                unansweredQuestions.removeAll()
            }
            lifecycle = .waitingForUser
            waitingRequestID = "\(offset):\(event.timestamp ?? "")"
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
                let incoming: [PendingQuestion] = (item.questions?.compactMap(\.title) ?? []).enumerated().compactMap { index, title in
                    guard !title.isEmpty else { return nil }
                    return PendingQuestion(
                        id: "\(offset):\(index):\(event.timestamp ?? "")",
                        title: title
                    )
                }
                guard !incoming.isEmpty else { return }
                // ponytail: 文案相同视为同一次请求，保留原标识。Codex 若用相同标题发出新的一次提问，再按事件偏移区分。
                if unansweredQuestions.allSatisfy({ $0.callID == nil }),
                   incoming.map(\.title) == unansweredQuestions.map(\.title) {
                    return
                }
                replaceQuestions(incoming)
            } else if item.type == "UserMessage" {
                consumeAnswer(item.content?.compactMap(\.text).joined(separator: "\n"))
            }
        default:
            break
        }
    }

    private mutating func replaceQuestions(_ incoming: [PendingQuestion]) {
        let previousCount = unansweredQuestions.count
        Self.logger.info(
            "更新待回复问题: previous=\(previousCount, privacy: .public) next=\(incoming.count, privacy: .public) toolCall=\(incoming.first?.callID != nil, privacy: .public)"
        )
        unansweredQuestions = incoming
        // 问题是覆盖层。底下若是更早的审批，回答后不能把那条旧请求找回来。
        if lifecycle == .waitingForUser {
            lifecycle = taskCompletedAt == nil ? .running : .completed
            waitingRequestID = nil
        }
    }

    private mutating func consumeToolResult(_ callID: String) {
        let count = unansweredQuestions.count
        unansweredQuestions.removeAll { $0.callID == callID }
        let removedCount = count - unansweredQuestions.count
        if removedCount > 0 {
            Self.logger.info("提问工具已返回，清除对应待回复: count=\(removedCount, privacy: .public)")
        }
    }

    /// 文本回答仅消费异步问题；工具提问必须等匹配结果或显式取消，避免插入消息误清。
    private mutating func consumeAnswer(_ message: String?) {
        guard let message, !message.isEmpty, !unansweredQuestions.isEmpty else { return }
        if message.hasPrefix("> "), let separator = message.range(of: "\n\n") {
            let title = String(message[message.index(message.startIndex, offsetBy: 2)..<separator.lowerBound])
            unansweredQuestions.removeAll { $0.callID == nil && $0.title == title }
        } else {
            unansweredQuestions.removeAll { $0.callID == nil }
        }
    }

    private static let eventEnvelopeMarker = Data("\"event_msg\"".utf8)
    private static let inputCallMarker = Data("\"request_user_input\"".utf8)
    private static let callOutputMarker = Data("\"function_call_output\"".utf8)
    private static let eventMarkers = [
        "task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted",
        "thread_rolled_back", "exec_approval_request", "apply_patch_approval_request",
        "request_permissions", "request_user_input", "elicitation_request", "item_completed"
    ].map { Data("\"\($0)\"".utf8) }
}
