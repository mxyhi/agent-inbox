import AppKit
import AgentInboxCore
import SwiftUI

// MARK: - 设置分类

/// 设置分类 —— 侧边栏每一项对应右侧一个面板
/// 后续新增设置项:在此追加一个 case,再补一个对应的 *SettingsSection 子视图即可
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case panel   // 浮窗行为
    case open    // 打开方式
    case data    // 数据来源
    case filter  // firstPrompt 过滤
    case about   // 关于

    var id: String { rawValue }

    /// 侧边栏显示名
    var label: String {
        switch self {
        case .panel: return "浮窗"
        case .open: return "打开方式"
        case .data: return "数据"
        case .filter: return "过滤"
        case .about: return "关于"
        }
    }

    /// 侧边栏图标(SF Symbol)
    var systemImage: String {
        switch self {
        case .panel: return "macwindow"
        case .open: return "arrow.up.forward.square"
        case .data: return "externaldrive"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 设置窗口

/// 设置窗口 —— 左侧分类栏 + 右侧详情,仿 macOS 系统设置
/// 固定 frame + 明确列宽,规避 NavigationSplitView 放进 Settings 场景时的尺寸自适应小毛病
struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var updateController: AppUpdateController

    // 当前选中分类;List 单选绑定要求可选类型,默认停在「浮窗」
    @State private var selection: SettingsCategory? = .panel

    var body: some View {
        NavigationSplitView {
            // 左侧分类栏
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.label, systemImage: category.systemImage)
                    .tag(category)
            }
            // 分类名都是两字,固定窄宽即可,顺带禁掉拖拽变宽
            .navigationSplitViewColumnWidth(140)
            .listStyle(.sidebar)
            // 设置窗口的分类栏应常驻,移除工具栏里那个折叠侧边栏的按钮
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // 右侧详情:按选中分类切换对应面板(nil 兜底回浮窗)
            detail(for: selection ?? .panel)
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 640, height: 480)
    }

    /// 分类 → 详情面板
    @ViewBuilder
    private func detail(for category: SettingsCategory) -> some View {
        switch category {
        case .panel:
            PanelSettingsSection(viewModel: viewModel)
        case .open:
            OpenSettingsSection(viewModel: viewModel)
        case .data:
            DataSettingsSection()
        case .filter:
            FilterSettingsSection(viewModel: viewModel)
        case .about:
            AboutSettingsSection(updateController: updateController)
        }
    }
}

// MARK: - 各分类面板

/// 浮窗行为
private struct PanelSettingsSection: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                Picker("置顶模式", selection: Binding(
                    get: { viewModel.pinMode },
                    set: { viewModel.setPinMode($0) }
                )) {
                    ForEach(PinMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                LabeledContent("浮窗位置") {
                    Button("重置到右上角") {
                        // 拖丢了找回来:FloatingPanelController 监听此通知归位并清空持久化
                        NotificationCenter.default.post(name: .resetPanelPosition, object: nil)
                    }
                }
            } footer: {
                Text("浮窗可整体拖动,位置会自动记住")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 数据来源(只读路径)
private struct DataSettingsSection: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Codex 会话目录") {
                    Text("~/.codex/sessions")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("状态存储") {
                    Text("~/Library/Application Support/Agent Inbox")
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
    @ObservedObject var viewModel: AppViewModel

    @State private var method: OpenSessionMethod
    @State private var customCommand: String
    @State private var isTestingCommand = false
    @State private var testResult: String?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _method = State(initialValue: viewModel.openSessionConfig.method)
        _customCommand = State(initialValue: viewModel.openSessionConfig.customCommand)
    }

    var body: some View {
        Form {
            Section {
                // 打开方式选择器
                Picker("打开方式", selection: $method) {
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

                // 自定义命令输入框（仅在选择自定义时显示）
                if method == .custom {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义命令")
                            .font(.headline)

                        TextField("输入 shell 命令模板", text: $customCommand, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3...6)
                            .onSubmit {
                                saveConfig()
                            }

                        // 变量说明
                        VStack(alignment: .leading, spacing: 4) {
                            Text("支持的变量：")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(OpenSessionConfig.supportedVariables, id: \.name) { variable in
                                HStack(spacing: 8) {
                                    Text(variable.name)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.blue)
                                    Text("—")
                                        .foregroundStyle(.tertiary)
                                    Text(variable.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        // 示例命令
                        VStack(alignment: .leading, spacing: 4) {
                            Text("示例命令：")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(OpenSessionConfig.exampleCommands, id: \.self) { example in
                                Text(example)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)

                        // 测试按钮
                        HStack {
                            Button("测试命令") {
                                testCommand()
                            }
                            .disabled(customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingCommand)

                            if isTestingCommand {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.leading, 8)
                            }

                            if let result = testResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(result.contains("成功") ? .green : .red)
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
            } footer: {
                Text("配置如何打开会话工作目录。更改会立即保存。")
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
            testResult = "❌ 没有可用的测试会话"
            return
        }

        isTestingCommand = true
        testResult = nil

        Task { @MainActor in
            do {
                let executor = OpenSessionExecutor()
                let config = OpenSessionConfig(method: .custom, customCommand: customCommand)
                try executor.execute(session: testSession, config: config)
                testResult = "✓ 命令执行成功"
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
            isTestingCommand = false

            // 3 秒后清空测试结果
            try? await Task.sleep(for: .seconds(3))
            testResult = nil
        }
    }
}

/// firstPrompt 过滤规则
private struct FilterSettingsSection: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题和说明
            VStack(alignment: .leading, spacing: 6) {
                Text("提示词过滤")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("符合条件的会话将自动跳过，不会出现在待办列表中")
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

                            Text("还没有过滤规则")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Text("添加规则后，匹配的会话将被自动过滤")
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

/// 关于(版本信息)
private struct AboutSettingsSection: View {
    @ObservedObject var updateController: AppUpdateController

    var body: some View {
        Form {
            Section {
                LabeledContent("版本") {
                    Text(AppVersion.displayValue(
                        shortVersionString: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ))
                        .foregroundStyle(.tertiary)
                }

                Button("检查更新…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 过滤规则编辑控件

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
            Picker("匹配方式", selection: $matchType) {
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
            .help("添加过滤规则")
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
            return "输入要过滤的关键词..."
        case .equals:
            return "输入要完全匹配的提示词..."
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
                    Text("按回车保存修改")
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
            .help("删除规则")
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
