# DSH 会话支持

依据 DeepSeek Harness `@deepseek-ai/dsh` 0.2.0-rc.2 的本机安装源码、CLI 帮助与官方文档核对（2026-10-18）。

## 数据来源

默认读取 `~/.dsh/sessions/<project>/<session-id>/session.v4.jsonl.zstd`，也支持明文 `session.v4.jsonl`。应用进程设置 `DSH_HOME` 时使用该目录下的 `sessions`。同时存在两种格式时优先压缩版。只读访问，不启动 DSH、不安装 hook、不重建缓存。

压缩读取复用本机 `zstd`；未安装时使用 DSH 所需、具备 `node:zlib.createZstdDecompress` 的 Node。图形应用需能在 PATH 或常见安装目录找到其中一种。未知日志版本、损坏或超限记录不生成完成待办。

`storages/session_projcache` 缺少准确完成时间和回合结束原因，且可能滞后，不能作为完成状态的权威来源。

## 状态映射

| 原生证据 | Inbox 行为 |
| --- | --- |
| `turn/start` | 运行中，清除上一轮完成信息 |
| `turn/end` 且 `reason.kind=completed` | 待确认，使用事件毫秒时间 |
| `aborted`、`error`、`interrupted`、`max-tokens` | 不生成完成待办 |
| `ask_user_question` | 展示最新待回复问题，以原生 callId 确认 |
| 工具返回 `{pending:true}` 或 `TOOL_OUTCOME_UNKNOWN` | 保留待回复，即使回合已结束 |
| 对应工具结果或 `user-question-reply` | 清除对应问题；普通输出不清除 |
| `delegationDepth>0`、`origin=subagent`、自己的 `subagent/descriptor` | 不单独列出子会话 |
| 父日志 `subagent/catalog` 对应的直接子会话仍有活宿主且正在运行 | 父会话保持运行中 |
| `session/end-seed` 且 `inherited=true` | 清除继承历史带来的完成、问题和子会话身份 |

`session.lock` 是空锁文件；实际排他锁用于核实宿主，文件存在或进程在线本身不意味着运行中。未落入原生日志的临时权限弹窗、脱离会话的外部后台进程不在本次识别范围。

## 集成与性能

默认启用 `.dsh`，复用现有标签、`dsh:<原生ID>` 身份、确认持久化、通知与打开工作目录行为。无数据库迁移，不改旧源的身份。打开命令边界见 [会话打开配置](../OPEN_SESSION_CONFIG.md)。

首次扫描恢复日志状态；后续按 inode、mtime、size 缓存。追加前检查日志头和断点附近各至多 256 字节，从完整记录或压缩帧之后继续解码；重写时重新解析，半行留到下次。历史默认最多 80 条主会话，活宿主不受此窗口限制。

所有源遵守 [性能规范](performance.md)。测试覆盖完成、中断、继续运行、问题超时和回复、继承历史、子会话、增删文件、压缩帧追加及解码量边界。
