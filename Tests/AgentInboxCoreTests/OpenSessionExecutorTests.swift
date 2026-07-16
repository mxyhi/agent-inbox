import XCTest
@testable import AgentInboxCore

/// OpenSessionExecutor 单元测试
final class OpenSessionExecutorTests: XCTestCase {
    var executor: OpenSessionExecutor!
    var mockSession: SessionSummary!

    override func setUp() {
        super.setUp()
        executor = OpenSessionExecutor()

        // 创建测试用 Mock 会话
        mockSession = SessionSummary(
            provider: .codex,
            sessionID: "test-session-123",
            filePath: "/tmp/rollout-test.jsonl",
            cwd: "/tmp/test-workspace",
            startedAt: Date(),
            modifiedAt: Date(),
            taskCompletedAt: nil,
            lastAgentMessage: nil,
            firstPrompt: "测试提示词"
        )
    }

    override func tearDown() {
        executor = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Finder 方式测试

    func testExecuteFinder_WithValidCwd() {
        // Given: 配置为 Finder 打开
        let config = OpenSessionConfig(method: .finder, customCommand: "")

        // When/Then: 执行不应抛出异常（实际会打开 Finder，测试环境下无副作用）
        XCTAssertNoThrow(try executor.execute(session: mockSession, config: config))
    }

    func testExecuteFinder_WithoutCwd() {
        // Given: 会话没有 cwd（应 fallback 到定位 rollout 文件）
        let sessionWithoutCwd = SessionSummary(
            provider: .codex,
            sessionID: "test-no-cwd",
            filePath: "/tmp/rollout-test.jsonl",
            cwd: nil,
            startedAt: Date(),
            modifiedAt: Date(),
            taskCompletedAt: nil,
            lastAgentMessage: nil
        )
        let config = OpenSessionConfig(method: .finder, customCommand: "")

        // When/Then: 执行不应抛出异常
        XCTAssertNoThrow(try executor.execute(session: sessionWithoutCwd, config: config))
    }

    // MARK: - 自定义命令测试

    func testExecuteCustom_VariableReplacement() throws {
        // Given: 自定义命令使用 echo 输出变量（echo 是无副作用的测试命令）
        let config = OpenSessionConfig(
            method: .custom,
            customCommand: "echo \"Session: $session_id, CWD: $cwd, File: $file_path, Project: $project_name\""
        )

        // When/Then: 执行成功（echo 总是返回 0）
        XCTAssertNoThrow(try executor.execute(session: mockSession, config: config))
    }

    func testExecuteCustom_EmptyCommand() {
        // Given: 空的自定义命令
        let config = OpenSessionConfig(method: .custom, customCommand: "")

        // When/Then: 应抛出 emptyCustomCommand 错误
        XCTAssertThrowsError(try executor.execute(session: mockSession, config: config)) { error in
            XCTAssertTrue(error is OpenSessionError)
            if case .emptyCustomCommand = error as? OpenSessionError {
                XCTAssertTrue(true)
            } else {
                XCTFail("期望 emptyCustomCommand 错误")
            }
        }
    }

    func testExecuteCustom_InvalidCommand() {
        // Given: 无效的 shell 命令（不存在的命令）
        let config = OpenSessionConfig(
            method: .custom,
            customCommand: "nonexistent_command_xyz_12345"
        )

        // When/Then: 应抛出 commandFailed 错误
        XCTAssertThrowsError(try executor.execute(session: mockSession, config: config)) { error in
            XCTAssertTrue(error is OpenSessionError)
            if case .commandFailed = error as? OpenSessionError {
                XCTAssertTrue(true)
            } else {
                XCTFail("期望 commandFailed 错误")
            }
        }
    }

    func testExecuteCustom_SuccessfulCommand() throws {
        // Given: 成功的 shell 命令（true 是 shell 内置命令，总是返回 0）
        let config = OpenSessionConfig(
            method: .custom,
            customCommand: "true"
        )

        // When/Then: 执行成功
        XCTAssertNoThrow(try executor.execute(session: mockSession, config: config))
    }

    func testExecuteCustom_FailingCommand() {
        // Given: 失败的 shell 命令（false 是 shell 内置命令，总是返回 1）
        let config = OpenSessionConfig(
            method: .custom,
            customCommand: "false"
        )

        // When/Then: 应抛出 commandFailed 错误
        XCTAssertThrowsError(try executor.execute(session: mockSession, config: config)) { error in
            if case .commandFailed(_, let exitCode, _) = error as? OpenSessionError {
                XCTAssertEqual(exitCode, 1)
            } else {
                XCTFail("期望 commandFailed 错误且退出码为 1")
            }
        }
    }

    // MARK: - 配置模型测试

    func testOpenSessionConfigDefaults() {
        // Given/When: 使用默认初始化
        let config = OpenSessionConfig()

        // Then: 默认为 Finder 方式，空命令
        XCTAssertEqual(config.method, .finder)
        XCTAssertEqual(config.customCommand, "")
    }

    func testOpenSessionMethodLabels() {
        // Given/When/Then: 验证各方式的标签
        XCTAssertEqual(OpenSessionMethod.finder.label, "Finder")
        XCTAssertEqual(OpenSessionMethod.terminal.label, "终端")
        XCTAssertEqual(OpenSessionMethod.vscode.label, "VS Code")
        XCTAssertEqual(OpenSessionMethod.custom.label, "自定义命令")
    }

    func testSupportedVariables() {
        // Given/When: 获取支持的变量列表
        let variables = OpenSessionConfig.supportedVariables

        // Then: 应包含会话 id/源/路径相关变量
        XCTAssertEqual(variables.count, 5)
        XCTAssertTrue(variables.contains { $0.name == "$session_id" })
        XCTAssertTrue(variables.contains { $0.name == "$provider" })
        XCTAssertTrue(variables.contains { $0.name == "$cwd" })
        XCTAssertTrue(variables.contains { $0.name == "$file_path" })
        XCTAssertTrue(variables.contains { $0.name == "$project_name" })
    }
}
