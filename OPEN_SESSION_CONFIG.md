# 会话打开配置

Agent Inbox 支持通过配置自定义如何打开 Codex 会话工作目录。

## 功能概述

在应用设置中，你可以选择不同的打开方式：

### 预设方式

1. **Finder**（默认）
   - 在 Finder 中打开工作目录
   - 如果会话没有 `cwd`，会在 Finder 中定位 rollout 文件

2. **终端**
   - 使用 Terminal.app 打开工作目录
   - 命令：`open -a Terminal "$cwd"`

3. **VS Code**
   - 使用 VS Code 打开工作目录
   - 命令：`code "$cwd"`
   - ⚠️ 需要先安装 VS Code 的 `code` 命令行工具

### 自定义命令

选择"自定义命令"后，可以输入任意 shell 命令模板。

## 变量替换

自定义命令支持以下变量：

| 变量 | 说明 | 示例值 |
|------|------|--------|
| `$session_id` | 会话 ID | `rollout-abc123` |
| `$cwd` | 工作目录路径 | `/Users/dev/workspace/my-project` |
| `$file_path` | rollout 文件完整路径 | `/Users/dev/.codex/sessions/rollout-abc123.jsonl` |
| `$project_name` | 项目名称（cwd 最后一段） | `my-project` |

## 示例命令

### 使用 Cursor 编辑器打开
```bash
cursor "$cwd"
```

### 在终端中打开并自动激活 Python 虚拟环境
```bash
open -a Terminal "$cwd" && osascript -e 'tell application "Terminal" to do script "cd \"$cwd\" && source venv/bin/activate" in front window'
```

### 在 iTerm2 中打开
```bash
open -a iTerm "$cwd"
```

### 打印会话信息（调试用）
```bash
echo "Opening session $session_id at $cwd"
```

### 使用自定义脚本
```bash
~/bin/open-session.sh "$session_id" "$cwd"
```

## 配置路径

配置保存在应用持久化存储中：
```
~/Library/Application Support/Agent Inbox/state.db
```

## 错误处理

- **空命令**：自定义命令为空时，会提示错误
- **命令执行失败**：如果命令返回非零退出码，会显示通知并记录错误日志
- **cwd 缺失**：Terminal/VS Code 方式在 cwd 缺失时会自动 fallback 到 Finder 定位 rollout 文件

## 测试命令

在设置面板中，点击"测试命令"按钮可以使用当前焦点会话测试你的自定义命令。

测试会：
1. 获取当前第一个待办或运行中的会话
2. 执行变量替换
3. 运行命令并捕获输出
4. 显示执行结果（成功 ✓ 或失败 ❌）

## 安全说明

- 自定义命令通过 `/bin/sh -c` 执行
- 命令在当前用户权限下运行，没有额外的沙盒限制
- 变量值会直接替换到命令中，请避免包含特殊字符的路径
- 建议仅配置你信任的命令

## 向后兼容

- 默认配置为 Finder 打开，现有用户升级后无需任何操作
- 旧版本的持久化数据会自动补充默认配置

## 技术实现

### 架构分层

1. **配置模型**（`OpenSessionConfig`）
   - `method`: 打开方式枚举
   - `customCommand`: 自定义命令模板

2. **执行引擎**（`OpenSessionExecutor`）
   - 根据配置分发到不同实现
   - 变量替换和 shell 命令执行
   - 错误捕获和日志记录

3. **集成层**（`AppViewModel`）
   - 读取配置并调用执行引擎
   - 错误通知和状态管理

4. **UI 层**（`SettingsView`）
   - 打开方式单选
   - 自定义命令输入和测试

### 错误类型

```swift
public enum OpenSessionError: LocalizedError {
    case emptyCustomCommand
    case commandFailed(command: String, exitCode: Int, stderr: String)
    case executionFailed(underlying: Error)
}
```

## 常见问题

### Q: VS Code 打开失败？
A: 确保已安装 `code` 命令。在 VS Code 中按 `Cmd+Shift+P`，搜索 "Shell Command: Install 'code' command in PATH"。

### Q: 自定义命令不生效？
A: 检查命令是否有语法错误，使用"测试命令"按钮验证。查看控制台日志获取详细错误信息。

### Q: 如何重置为默认配置？
A: 在设置中选择"Finder"即可恢复默认行为。

### Q: 变量替换后命令太长？
A: 可以将复杂逻辑写入独立脚本，通过 `~/bin/my-script.sh "$session_id" "$cwd"` 调用。
