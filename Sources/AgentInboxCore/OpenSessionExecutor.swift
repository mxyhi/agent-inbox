import AppKit
import Foundation
import OSLog

/// 会话打开执行引擎 —— 根据配置以不同方式打开会话工作目录
/// 支持 Finder/Terminal/VS Code 预设方式,以及自定义 shell 命令模板
public final class OpenSessionExecutor {
    private let logger = Logger(subsystem: "agent-inbox", category: "OpenSessionExecutor")

    public init() {}

    /// 执行会话打开操作
    /// - Parameters:
    ///   - session: 会话摘要（包含 sessionID/cwd/filePath/projectName）
    ///   - config: 打开配置（方式 + 自定义命令模板）
    /// - Throws: 执行失败时抛出错误
    public func execute(
        session: SessionSummary,
        config: OpenSessionConfig
    ) throws {
        logger.info(
            "执行会话打开: method=\(config.method.rawValue, privacy: .public), provider=\(session.provider.rawValue, privacy: .public), session=\(session.sessionID, privacy: .public)"
        )

        switch config.method {
        case .finder:
            executeFinder(session: session)
        case .terminal:
            try executeTerminal(session: session)
        case .vscode:
            try executeVSCode(session: session)
        case .custom:
            try executeCustom(session: session, template: config.customCommand)
        }
    }

    // MARK: - 预设方式实现

    /// Finder 打开目录（默认方式）
    /// cwd 存在时打开目录，缺失时在 Finder 中定位会话文件/目录
    private func executeFinder(session: SessionSummary) {
        if let cwd = session.cwd, !cwd.isEmpty {
            NSWorkspace.shared.open(URL(filePath: cwd))
            logger.info("Finder 打开目录: \(cwd, privacy: .public)")
        } else {
            // cwd 缺失：在 Finder 中高亮会话路径
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: session.filePath)])
            logger.info("cwd 缺失，Finder 定位会话路径: \(session.filePath, privacy: .public)")
        }
    }

    /// Terminal 打开目录
    /// 使用 `open -a Terminal` 命令在终端中打开工作目录
    private func executeTerminal(session: SessionSummary) throws {
        guard let cwd = session.cwd, !cwd.isEmpty else {
            logger.warning("Terminal 打开失败: cwd 缺失，fallback 到 Finder")
            executeFinder(session: session)
            return
        }

        let command = "open -a Terminal \"\(cwd)\""
        try executeShellCommand(command)
        logger.info("Terminal 打开目录: \(cwd, privacy: .public)")
    }

    /// VS Code 打开目录
    /// 使用 `code` 命令打开工作目录（需用户已安装 VS Code 并配置 code 命令）
    private func executeVSCode(session: SessionSummary) throws {
        guard let cwd = session.cwd, !cwd.isEmpty else {
            logger.warning("VS Code 打开失败: cwd 缺失，fallback 到 Finder")
            executeFinder(session: session)
            return
        }

        let command = "code \"\(cwd)\""
        try executeShellCommand(command)
        logger.info("VS Code 打开目录: \(cwd, privacy: .public)")
    }

    /// 执行自定义命令模板
    /// 支持变量替换: $session_id, $cwd, $file_path, $project_name
    private func executeCustom(session: SessionSummary, template: String) throws {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenSessionError.emptyCustomCommand
        }

        // 变量替换（按最长匹配优先，避免 $session_id 被 $session 部分替换）
        // $session_id 使用源原生 id,便于 `grok --resume` 等命令直接消费
        var command = trimmed
        command = command.replacingOccurrences(of: "$session_id", with: session.sessionID)
        command = command.replacingOccurrences(of: "$cwd", with: session.cwd ?? "")
        command = command.replacingOccurrences(of: "$file_path", with: session.filePath)
        command = command.replacingOccurrences(of: "$project_name", with: session.projectName)
        command = command.replacingOccurrences(of: "$provider", with: session.provider.rawValue)

        logger.info("执行自定义命令: \(command, privacy: .public)")
        try executeShellCommand(command)
    }

    // MARK: - Shell 命令执行

    /// 通过 /bin/sh 执行 shell 命令
    /// - Parameter command: shell 命令字符串
    /// - Throws: 命令执行失败时抛出 OpenSessionError
    private func executeShellCommand(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        // 捕获标准输出和标准错误
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            // 检查退出状态码
            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                logger.error("命令执行失败: status=\(process.terminationStatus), stderr=\(errorOutput, privacy: .public)")
                throw OpenSessionError.commandFailed(
                    command: command,
                    exitCode: Int(process.terminationStatus),
                    stderr: errorOutput
                )
            }

            logger.debug("命令执行成功: \(command, privacy: .public)")
        } catch let error as OpenSessionError {
            throw error
        } catch {
            logger.error("命令执行异常: \(String(describing: error), privacy: .public)")
            throw OpenSessionError.executionFailed(underlying: error)
        }
    }
}

// MARK: - 错误定义

/// 会话打开执行错误
public enum OpenSessionError: LocalizedError {
    /// 自定义命令为空
    case emptyCustomCommand
    /// 命令执行失败（非零退出码）
    case commandFailed(command: String, exitCode: Int, stderr: String)
    /// 命令执行异常
    case executionFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .emptyCustomCommand:
            return "自定义命令不能为空"
        case .commandFailed(let command, let exitCode, let stderr):
            let preview = command.prefix(50)
            return "命令执行失败 (退出码 \(exitCode)): \(preview)\n\(stderr)"
        case .executionFailed(let underlying):
            return "命令执行异常: \(underlying.localizedDescription)"
        }
    }
}
