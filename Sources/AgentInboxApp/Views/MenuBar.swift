import AppKit
import AgentInboxCore
import SwiftUI

// MARK: - 菜单栏内容

/// 菜单栏下拉菜单 —— 保持系统原生交互
/// V4:摘要行显示「N 个待办 · M 个运行中」,待办可直接在菜单里逐个完成。
struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    let toggleWindow: () -> Void

    var body: some View {
        // 状态摘要(纯展示)
        Text(viewModel.menuSummary)

        Divider()

        // 待办操作区:逐个完成 + 批量完成
        if viewModel.snapshot.hasTodo {
            ForEach(viewModel.snapshot.todos.prefix(5)) { session in
                Button("完成「\(session.projectName)」") {
                    viewModel.completeTodo(id: session.id)
                }
            }

            if viewModel.snapshot.todos.count > 1 {
                Button("全部标记完成") {
                    if confirmCompleteAllTodos(count: viewModel.snapshot.todos.count) {
                        viewModel.completeAllTodos()
                    }
                }
            }

            Divider()
        }

        Button("立即刷新") {
            viewModel.refreshNow()
        }

        Button(viewModel.panelVisibilityMenuTitle) {
            toggleWindow()
        }

        Divider()

        // 置顶模式(系统原生子菜单样式)
        Picker("置顶模式", selection: Binding(
            get: { viewModel.pinMode },
            set: { viewModel.setPinMode($0) }
        )) {
            ForEach(PinMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }

        Divider()

        SettingsMenuButton()

        Button("退出 Agent Inbox") {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 设置窗口

/// 设置窗口 —— 系统原生 Form 样式
struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            // 浮窗行为
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
            } header: {
                Text("浮窗")
            } footer: {
                Text("浮窗可整体拖动,位置会自动记住")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // 数据来源
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
            } header: {
                Text("数据")
            }

            Section {
                PromptFilterRuleEditor { pattern, matchType in
                    viewModel.addPromptFilterRule(pattern: pattern, matchType: matchType)
                }

                if viewModel.promptFilterRules.isEmpty {
                    Text("暂无过滤规则")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
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
            } header: {
                Text("firstPrompt 过滤")
            } footer: {
                Text("命中规则的已完成会话不会进入待办,也不会被标记为完成")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // 版本
            Section {
                LabeledContent("版本") {
                    Text(AppVersion.displayValue(
                        shortVersionString: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }
}

private struct PromptFilterRuleEditor: View {
    let onAdd: (String, PromptFilterMatchType) -> Void

    @State private var pattern = ""
    @State private var matchType: PromptFilterMatchType = .contains

    // 去除首尾空白后的输入,用于判空与提交
    private var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 8) {
            // 匹配方式:分段控件比下拉更直观,只有「包含 / 正则」两项
            Picker("匹配方式", selection: $matchType) {
                ForEach(PromptFilterMatchType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            // firstPrompt 片段或正则;回车即添加
            TextField("firstPrompt 片段或正则", text: $pattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)

            // 主操作按钮,输入为空时禁用
            Button("添加", action: add)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedPattern.isEmpty)
        }
    }

    private func add() {
        guard !trimmedPattern.isEmpty else { return }
        onAdd(pattern, matchType)
        pattern = ""
        matchType = .contains
    }
}

private struct PromptFilterRuleRow: View {
    let rule: PromptFilterRule
    let onEnabledChange: (Bool) -> Void
    let onUpdate: (String, PromptFilterMatchType) -> Void
    let onDelete: () -> Void

    @State private var pattern: String
    @State private var matchType: PromptFilterMatchType

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
        HStack(spacing: 8) {
            // 启用开关:关闭后规则不再命中,pattern 文本转灰提示
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { onEnabledChange($0) }))
                .labelsHidden()
                .controlSize(.small)

            // 匹配方式:紧凑菜单,改动后由「保存」提交
            Picker("匹配方式", selection: $matchType) {
                ForEach(PromptFilterMatchType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .fixedSize()

            // 可就地编辑的 pattern,回车即保存
            TextField("firstPrompt 片段或正则", text: $pattern)
                .textFieldStyle(.plain)
                .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                .onSubmit(save)

            Spacer(minLength: 0)

            // 仅在有未保存改动时出现,避免每行都堆按钮
            if hasChanges {
                Button("保存", action: save)
                    .buttonStyle(.borderless)
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("删除过滤规则")
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
