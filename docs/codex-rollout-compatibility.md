# Codex rollout 兼容性核对（2026-10-22）

## 修复范围

本机 Codex CLI 0.163.0 的 TUI 选择题在日志中保存为 `response_item/function_call`，工具名为 `request_user_input`，问题正文在 JSON 字符串 `arguments.questions[].question` 中。原解析器只消费 `event_msg`，会把已等待回答的会话继续判为运行中，无法产生新待办通知。

现在通过 `call_id` 关联提问和 `function_call_output`。同名新问题用新的调用 ID 区分；重复记录不重复提醒，旧调用的迟到结果不能清除新问题。工具错误或取消结果也结束本次等待；`turn_aborted`、`thread_rolled_back` 清理待回复。普通用户消息不代替该工具的回答结果。完整回放、追加读取及重启恢复共用原有解析器。

另补齐 `event_msg/item_completed/UserMessage` 的首条用户提示词提取，恢复新版会话摘要和依赖提示词的过滤。继续忽略 `response_item/message role=user` 的注入上下文，保留 256KiB 文件头读取上限。

异步提问仍按 `item_completed/AgentMessage delivery=async` 及对应用户消息处理。`request_user_input_async` 的 `accepted=true` 只是提交成功，不能作为用户已回答。

## 上游核对与边界

核对了当前本机会话日志，以及 openai/codex 提交 `342ed69a174c206c1de52a59491b131e0753cfa5`：

- [rollout 持久化策略](https://github.com/openai/codex/blob/342ed69a174c206c1de52a59491b131e0753cfa5/codex-rs/rollout/src/policy.rs)：FunctionCall/FunctionCallOutput 会持久化；RequestUserInput、ExecApprovalRequest、ApplyPatchApprovalRequest、RequestPermissions、ElicitationRequest 属于非持久化事件。
- [提问处理器](https://github.com/openai/codex/blob/342ed69a174c206c1de52a59491b131e0753cfa5/codex-rs/core/src/tools/handlers/request_user_input.rs)：等待回答后返回工具结果；不可用或取消也返回错误结果。
- `task_started`、`task_complete`、`item_completed`、`turn_aborted` 仍见于当前日志，现有生命周期解析继续适用。

普通命令、补丁或 MCP 调用可能直接执行、自动批准或等待人工审批，仅有调用记录无法区分。当前日志监控不能可靠识别这类未持久化的审批状态；不能将所有未返回的工具都标为待审批。若需覆盖，需额外接入真实审批事件源。

## 验证

新增 7 项回归测试，覆盖通知转换、匹配回答、重复标题的新请求、已确认状态、迟到结果、结束/取消、错误结果、半行追加、协议文本伪装及新版首提示词。全量 126 项测试（116 项 Swift Testing、10 项 XCTest）与严格并发 Release 构建通过。

截图对应的真实日志只读复制到临时目录，回放到提问、重启恢复，再追加实际回答。原日志不修改，测试夹具不保存真实业务内容。

| 指标 | 原代码 | 修复后 |
| --- | --- | --- |
| 提问时待回复 | false | true |
| 新待办数 | 0 | 1 |
| 重启后待回复 | false | true |
| 回答后无待回复 | true（从未识别） | true |
| 首条提示词提取 | false | true |

同一机器、77 条当前主会话、优化编译：冷扫描 965.44 → 978.01ms；20 次未变化路径刷新中位数 0.318 → 0.340ms，P95 0.361 → 0.392ms；基准最大 RSS 51.58 → 52.14MiB。该单轮数据用于观察本次开销，不代表任意数据规模的性能保证；未增加轮询和全量工具输出解码。

以上为源码阶段验证，发布产物、安装版本和启动状态在发版时另行核验；macOS 通知横幅需单独实测。应用首次扫描历史待办仍按原语义保持静默。
