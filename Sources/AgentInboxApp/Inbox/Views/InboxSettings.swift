import AppKit
import AgentInboxCore
import SwiftUI

// MARK: - Agent Inbox 设置页

/// Agent Inbox 设置分类。设置窗口是 tic 的标签页式 `Settings`，这里作为其中一个标签，内部用分段控件切换。
enum InboxSettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case open    // 打开方式
    case data    // 数据来源
    case filter  // firstPrompt 过滤
    case network // 更新网络

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: return String(localized: "Open With")
        case .data: return String(localized: "Data")
        case .filter: return String(localized: "Filters")
        case .network: return String(localized: "Network")
        }
    }
}

/// 设置窗口的「Agent Inbox」标签。
struct InboxSettings: View {
    @State private var selection: InboxSettingsCategory = .open
    private var model: AppModel { AppModel.shared }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(InboxSettingsCategory.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            detail(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 470)
    }

    @ViewBuilder
    private func detail(for category: InboxSettingsCategory) -> some View {
        switch category {
        case .open:
            OpenSettingsSection(viewModel: model.inbox)
        case .data:
            DataSettingsSection()
        case .filter:
            FilterSettingsSection(viewModel: model.inbox)
        case .network:
            NetworkSettingsSection(viewModel: model.inbox, updateController: model.updater)
        }
    }
}

// MARK: - 各分类面板

/// 数据来源(只读路径)
private struct DataSettingsSection: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Codex sessions") {
                    Text(verbatim: "~/.codex/sessions")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Grok sessions") {
                    Text(verbatim: "~/.grok/sessions")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Claude sessions") {
                    Text(verbatim: "~/.claude/projects")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("DSH sessions") {
                    Text(DshSessionMonitor.defaultSessionsRoot.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("State storage") {
                    Text(verbatim: "~/Library/Application Support/Agent Inbox")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 打开方式配置
private struct OpenSettingsSection: View {
    let viewModel: InboxModel

    @State private var method: OpenSessionMethod
    @State private var customCommand: String
    @State private var isTestingCommand = false
    @State private var testResult: CommandTestResult?

    init(viewModel: InboxModel) {
        self.viewModel = viewModel
        _method = State(initialValue: viewModel.openSessionConfig.method)
        _customCommand = State(initialValue: viewModel.openSessionConfig.customCommand)
    }

    var body: some View {
        Form {
            Section {
                // 打开方式选择器
                Picker("Open With", selection: $method) {
                    ForEach(OpenSessionMethod.allCases) { method in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.label)
                                .font(.body)
                            Text(method.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(method)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: method) { _, newValue in
                    saveConfig()
                }

                // 自定义命令配置区域（仅在选择自定义时显示）
                if method == .custom {
                    Divider()
                        .padding(.vertical, 4)

                    // 命令模板输入
                    LabeledContent {
                        TextField("", text: $customCommand, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(2...4)
                            .multilineTextAlignment(.leading) // 强制左对齐
                            .onSubmit { saveConfig() }
                    } label: {
                        Text("Template")
                            .frame(width: 80, alignment: .trailing)
                    }

                    // 变量参考表格 —— 紧凑的两列布局
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Variables")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                                ForEach(OpenSessionConfig.supportedVariables, id: \.name) { variable in
                                    GridRow {
                                        Text(variable.name)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.blue)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(variable.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .backgroundStyle(Color(nsColor: .controlBackgroundColor))

                    // 示例命令 —— 代码块风格
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Examples")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(OpenSessionConfig.exampleCommands, id: \.self) { example in
                                    Text(example)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                        .padding(.leading, 2)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .backgroundStyle(Color(nsColor: .textBackgroundColor))

                    // 测试区域 —— 独立行，视觉上与输入区分离
                    HStack(spacing: 12) {
                        Button {
                            testCommand()
                        } label: {
                            HStack(spacing: 4) {
                                if isTestingCommand {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "play.circle")
                                        .font(.caption)
                                }
                                Text("Test Command")
                                    .font(.caption)
                            }
                        }
                        .disabled(customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingCommand)

                        if let result = testResult {
                            HStack(spacing: 4) {
                                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.caption)
                                Text(result.message)
                                    .font(.caption)
                            }
                            .foregroundStyle(result.succeeded ? .green : .red)
                        }
                    }
                    .padding(.top, 4)
                }
            } footer: {
                Text("Choose how to open a session's working directory. Changes are saved right away.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    /// 保存配置到 ViewModel
    private func saveConfig() {
        let config = OpenSessionConfig(
            method: method,
            customCommand: customCommand
        )
        viewModel.setOpenSessionConfig(config)
        testResult = nil // 清空测试结果
    }

    /// 测试自定义命令（使用当前焦点会话）
    private func testCommand() {
        guard method == .custom else { return }
        guard let testSession = viewModel.snapshot.todos.first ?? viewModel.snapshot.running.first else {
            testResult = CommandTestResult(succeeded: false, message: String(localized: "No session to test with"))
            return
        }

        isTestingCommand = true
        testResult = nil

        Task { @MainActor in
            do {
                let executor = OpenSessionExecutor()
                let config = OpenSessionConfig(method: .custom, customCommand: customCommand)
                try executor.execute(session: testSession, config: config)
                testResult = CommandTestResult(succeeded: true, message: String(localized: "Command ran successfully"))
            } catch {
                testResult = CommandTestResult(succeeded: false, message: error.localizedDescription)
            }
            isTestingCommand = false

            // 3 秒后清空测试结果
            try? await Task.sleep(for: .seconds(3))
            testResult = nil
        }
    }
}

/// 自定义命令的测试结果；成功与否显式记录，不从文案里猜。
private struct CommandTestResult {
    let succeeded: Bool
    let message: String
}

/// firstPrompt 过滤规则
private struct FilterSettingsSection: View {
    let viewModel: InboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题和说明
            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt Filters")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Matching sessions are skipped and won't show up as todos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)

            Divider()

            // 添加规则编辑器
            PromptFilterRuleEditor { pattern, matchType in
                viewModel.addPromptFilterRule(pattern: pattern, matchType: matchType)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // 规则列表
            ScrollView {
                VStack(spacing: 8) {
                    if viewModel.promptFilterRules.isEmpty {
                        // 空状态提示
                        VStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)

                            Text("No filter rules yet")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Text("Once you add a rule, matching sessions are filtered out automatically.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(viewModel.promptFilterRules) { rule in
                            PromptFilterRuleRow(
                                rule: rule,
                                onEnabledChange: { isEnabled in
                                    viewModel.setPromptFilterRuleEnabled(id: rule.id, isEnabled: isEnabled)
                                },
                                onUpdate: { pattern, matchType in
                                    viewModel.updatePromptFilterRule(
                                        id: rule.id,
                                        pattern: pattern,
                                        matchType: matchType
                                    )
                                },
                                onDelete: {
                                    viewModel.deletePromptFilterRule(id: rule.id)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

/// 更新网络代理配置
private struct NetworkSettingsSection: View {
    let viewModel: InboxModel
    let updateController: AppUpdateController

    @State private var proxyURLString: String

    init(viewModel: InboxModel, updateController: AppUpdateController) {
        self.viewModel = viewModel
        self.updateController = updateController
        let config = viewModel.updateProxyConfig
        _proxyURLString = State(initialValue: config.urlString)
    }

    private var validationMessage: String? {
        let config = NetworkProxyConfig(urlString: proxyURLString)
        guard !config.isEmpty else { return nil }
        guard config.isUsable else {
            return String(localized: "Enter a full URL, such as http://127.0.0.1:7890 or socks5://127.0.0.1:7890")
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                // 手动对齐这一行,避免 LabeledContent 默认基线让 rounded TextField 视觉偏低。
                HStack(alignment: .center, spacing: 12) {
                    Text("Proxy")

                    Spacer(minLength: 12)

                    TextField("", text: $proxyURLString)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 320, height: 24, alignment: .leading)
                        .onSubmit { saveIfValid() }
                        .onChange(of: proxyURLString) { _, _ in saveIfValid() }
                }
                .frame(minHeight: 28)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Leave empty to use no proxy. Only affects checking for and downloading updates.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveIfValid() {
        let config = NetworkProxyConfig(urlString: proxyURLString).normalized
        guard config.isEmpty || config.isUsable else { return }

        viewModel.setUpdateProxyConfig(config)
        updateController.applyProxyConfig(config)
    }
}

/// 新增过滤规则的输入行:匹配方式 + pattern + 添加按钮
private struct PromptFilterRuleEditor: View {
    let onAdd: (String, PromptFilterMatchType) -> Void

    @State private var pattern = ""
    @State private var matchType: PromptFilterMatchType = .contains

    // 去除首尾空白后的输入,用于判空与提交
    private var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 匹配方式:分段控件,只有「包含 / 等于」两项
            Picker("Match", selection: $matchType) {
                ForEach(PromptFilterMatchType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 120)

            // 输入框:根据匹配方式显示不同的提示文案
            TextField(placeholderText, text: $pattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)

            // 添加按钮:使用图标
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .disabled(trimmedPattern.isEmpty)
            .help("Add filter rule")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
        )
    }

    /// 根据匹配类型返回对应的占位符文案
    private var placeholderText: String {
        switch matchType {
        case .contains:
            return String(localized: "Keyword to filter out…")
        case .equals:
            return String(localized: "Exact prompt to filter out…")
        }
    }

    private func add() {
        guard !trimmedPattern.isEmpty else { return }
        onAdd(pattern, matchType)
        pattern = ""
        matchType = .contains
    }
}

/// 单条过滤规则行:启用开关 + 匹配方式 + 可就地编辑的 pattern + 保存/删除
private struct PromptFilterRuleRow: View {
    let rule: PromptFilterRule
    let onEnabledChange: (Bool) -> Void
    let onUpdate: (String, PromptFilterMatchType) -> Void
    let onDelete: () -> Void

    @State private var pattern: String
    @State private var matchType: PromptFilterMatchType
    @State private var isHovered = false

    init(
        rule: PromptFilterRule,
        onEnabledChange: @escaping (Bool) -> Void,
        onUpdate: @escaping (String, PromptFilterMatchType) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.rule = rule
        self.onEnabledChange = onEnabledChange
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _pattern = State(initialValue: rule.pattern)
        _matchType = State(initialValue: rule.matchType)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 启用开关:关闭后规则不再命中,pattern 文本转灰提示
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { onEnabledChange($0) }))
                .labelsHidden()
                .controlSize(.regular)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                // 匹配方式标签 + pattern
                HStack(spacing: 8) {
                    // 匹配方式小标签
                    Text(matchType.label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(matchTypeBadgeColor)
                        )
                        .foregroundStyle(matchTypeForegroundColor)

                    // 可编辑的 pattern
                    TextField("", text: $pattern)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                        .onSubmit(save)
                }

                // 仅在有改动时显示保存提示
                if hasChanges {
                    Text("Press Return to save")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }

            Spacer(minLength: 0)

            // 删除按钮:悬停时显示
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0.3)
            .help("Delete rule")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rule.isEnabled ? Color(NSColor.controlBackgroundColor) : Color(NSColor.controlBackgroundColor).opacity(0.5))
                .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hasChanges ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // 匹配方式标签的背景色
    private var matchTypeBadgeColor: Color {
        switch matchType {
        case .contains:
            return Color.blue.opacity(0.15)
        case .equals:
            return Color.purple.opacity(0.15)
        }
    }

    // 匹配方式标签的前景色
    private var matchTypeForegroundColor: Color {
        switch matchType {
        case .contains:
            return .blue
        case .equals:
            return .purple
        }
    }

    // pattern(去空白后非空且有变化)或匹配方式改变时可保存
    private var hasChanges: Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && (trimmed != rule.pattern || matchType != rule.matchType)
    }

    private func save() {
        guard hasChanges else { return }
        onUpdate(pattern, matchType)
    }
}
