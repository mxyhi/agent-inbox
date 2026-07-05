import AppKit
import AgentInboxCore
import SwiftUI

// MARK: - 焦点卡(列表首个待办)

/// 焦点卡 —— 顺序第一个待办的「突出」形态。
/// 用橙色语义底 + 描边把它从素行里抬起来,内含「问」(首个用户提示词)/「答」(Codex 最后交付)
/// 双段上下文,以及一排行动:打开会话 + 长按完成。其余待办保持单行素行,一张富卡压一列素行即焦点。
struct FocusTodoCard: View {
    let session: CodexSessionSummary
    /// 「打开↗」—— 跳到会话工作目录
    let onOpen: () -> Void
    /// 长按完成 —— 从快照剔除该待办
    let onComplete: () -> Void
    /// 用当前 firstPrompt 创建过滤规则
    let onCreateFilter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.segmentTagSpacing) {
            // 顶行:涟漪橙点 + 项目名 + 完成时间
            HStack(spacing: DS.Metrics.rowSpacing) {
                StatusOrb(kind: .todo)

                Text(session.projectName)
                    .font(DS.Fonts.focusTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                RelativeTimeText(date: session.taskCompletedAt ?? session.modifiedAt)
            }

            // 问:这活儿的由来(首个用户提示词),缺失则不渲染
            if let prompt = trimmedPrompt {
                SegmentLine(
                    systemImage: "quote.opening",
                    tagColor: .secondary,
                    text: prompt,
                    font: DS.Fonts.focusPrompt,
                    textColor: .secondary,
                    lineLimit: 1
                )
            }

            // 答:Codex 干完了什么(等你确认的核心),缺失则不渲染
            if let answer = trimmedAnswer {
                SegmentLine(
                    systemImage: "sparkles",
                    tagColor: DS.Colors.todo,
                    text: answer,
                    font: DS.Fonts.focusAnswer,
                    textColor: .primary.opacity(0.9),
                    lineLimit: 2
                )
            }

            // 行动行:打开(弱 ghost) + 长按完成(进度环)
            HStack(spacing: DS.Metrics.rowSpacing) {
                Spacer(minLength: 0)
                OpenButton(action: onOpen)
                HoldToCompleteButton(action: onComplete)
            }
        }
        .padding(.horizontal, DS.Metrics.focusCardPadH)
        .padding(.vertical, DS.Metrics.focusCardPadV)
        .background(
            RoundedRectangle(cornerRadius: DS.Metrics.focusCardRadius, style: .continuous)
                .fill(DS.Colors.focusCardFill)
        )
        // 橙色发丝描边:浅/深壁纸下都立得住卡边界
        .overlay(
            RoundedRectangle(cornerRadius: DS.Metrics.focusCardRadius, style: .continuous)
                .strokeBorder(DS.Colors.focusCardStroke, lineWidth: 0.5)
        )
        // 无障碍:整卡合并为一个元素,提供「标记完成」「打开会话」两个动作
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("待办:\(session.projectName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: "标记完成", onComplete)
        .accessibilityAction(named: "打开会话", onOpen)
        .contextMenu {
            if trimmedPrompt != nil {
                Button("按此提示词过滤") {
                    onCreateFilter()
                }
            }
        }
    }

    /// 首个用户提示词(去空白;空则不渲染)
    private var trimmedPrompt: String? {
        session.firstPrompt?.trimmed
    }

    /// Codex 最后一条消息(去空白;空则不渲染)
    private var trimmedAnswer: String? {
        session.lastAgentMessage?.trimmed
    }

    /// VoiceOver 朗读值:把问/答拼成一句
    private var accessibilityValue: String {
        [trimmedPrompt.map { "问:\($0)" }, trimmedAnswer.map { "答:\($0)" }]
            .compactMap { $0 }
            .joined(separator: ";")
    }
}

// MARK: - 问/答 段

/// 带前缀图标的单段文本 —— 图标占位宽与状态光点框对齐,使正文与上方标题左对齐成列。
/// 用 SF Symbol(单色)替代「问/答」文字:更贴合「状态不靠文字标签」的设计语言。
private struct SegmentLine: View {
    /// 段前缀 SF Symbol 名(问=引号符、答=闪光符)
    let systemImage: String
    let tagColor: Color
    let text: String
    let font: Font
    let textColor: Color
    let lineLimit: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Metrics.rowSpacing) {
            Image(systemName: systemImage)
                .font(DS.Fonts.segmentTag)
                .foregroundStyle(tagColor)
                // 与状态光点框同宽,让正文对齐到标题文字列
                .frame(width: DS.Metrics.orbFrame, alignment: .center)

            Text(text)
                .font(font)
                .foregroundStyle(textColor)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 待办行(其余待办)

/// 待办行 —— 涟漪橙点 + 项目名 + 相对时间 + 长按完成。
/// V4.1:摘要归焦点卡独占,其余待办一律单行紧凑,强化「单一焦点」。
struct TodoRow: View {
    let session: CodexSessionSummary
    let onComplete: () -> Void
    let onCreateFilter: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Metrics.rowSpacing) {
            StatusOrb(kind: .todo)

            Text(session.projectName)
                .font(DS.Fonts.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            RelativeTimeText(date: session.taskCompletedAt ?? session.modifiedAt)

            HoldToCompleteButton(action: onComplete)
        }
        .padding(.vertical, DS.Metrics.rowPaddingV)
        .padding(.horizontal, DS.Metrics.rowPaddingH)
        .background(
            RoundedRectangle(cornerRadius: DS.Metrics.rowRadius, style: .continuous)
                .fill(isHovered ? DS.Colors.rowHover : .clear)
        )
        .animation(DS.Anim.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("待办:\(session.projectName)")
        .accessibilityAction(named: "标记完成", onComplete)
        .contextMenu {
            if session.firstPrompt?.trimmed != nil {
                Button("按此提示词过滤") {
                    onCreateFilter()
                }
            }
        }
    }
}

// MARK: - 运行行

/// 运行行 —— 呼吸蓝点 + 项目名 + 实时跳动的运行时长
/// 无操作,纯感知;所以不做 hover 高亮,保持安静。
struct RunningRow: View {
    let session: CodexSessionSummary

    var body: some View {
        HStack(spacing: DS.Metrics.rowSpacing) {
            StatusOrb(kind: .running)

            Text(session.projectName)
                .font(DS.Fonts.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            // 运行时长:session_meta 启动时间;缺失时退化为文件 mtime
            ElapsedTimeText(since: session.startedAt ?? session.modifiedAt)
        }
        .padding(.vertical, DS.Metrics.rowPaddingV)
        .padding(.horizontal, DS.Metrics.rowPaddingH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("运行中:\(session.projectName)")
    }
}

// MARK: - 打开按钮(焦点卡次动作)

/// 「打开↗」—— 弱 ghost 文字按钮,hover 才浮出淡底,跳到会话工作目录。
struct OpenButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("打开")
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(DS.Fonts.actionOpen)
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? DS.Colors.rowHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .animation(DS.Anim.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .help("打开会话目录")
        // 卡级 a11y 已提供「打开会话」动作,避免 VoiceOver 重复
        .accessibilityHidden(true)
    }
}

// MARK: - 长按完成按钮

/// 长按完成 —— 单击太轻率(卡是「确认」语义),改为按住 holdToComplete 才触发,防误触。
/// 按住时外圈进度环从 12 点顺时针填满;中途松手环回抽、不触发;按满震一下 + 填绿后通知上层剔除。
/// 这是列表上唯一的按钮(焦点卡另有「打开」)。VoiceOver 走 accessibilityAction 直接触发,不要求按住。
struct HoldToCompleteButton: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 进度环填充度 0→1
    @State private var progress: CGFloat = 0
    /// 是否正在按住(驱动按钮微缩)
    @State private var isPressing = false
    /// 是否已完成(填绿 + 阻止松手回抽)
    @State private var didComplete = false
    /// 鼠标悬停状态
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // 底圈:默认低调灰,悬停时(未按下)变为 rowHover 底色,完成瞬间填绿
            Circle()
                .fill(didComplete ? DS.Colors.done : (isHovered && !isPressing ? DS.Colors.rowHover : DS.Colors.buttonIdle))
                .frame(width: DS.Metrics.completeButtonSize, height: DS.Metrics.completeButtonSize)

            // hover 提示环:仅在悬停且未按下时显示橙色细环,暗示长按操作
            if isHovered && !isPressing && !didComplete {
                Circle()
                    .stroke(DS.Colors.todo.opacity(0.4), lineWidth: 1.5)
                    .frame(
                        width: DS.Metrics.completeButtonFrame - 1,
                        height: DS.Metrics.completeButtonFrame - 1
                    )
            }

            // 长按进度环:12 点起笔(-90°)顺时针填充
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    DS.Colors.todo,
                    style: StrokeStyle(lineWidth: DS.Metrics.completeRingWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(
                    width: DS.Metrics.completeButtonFrame - DS.Metrics.completeRingWidth,
                    height: DS.Metrics.completeButtonFrame - DS.Metrics.completeRingWidth
                )
                .opacity(progress > 0 ? 1 : 0)

            // checkmark 图标:悬停时(未按下)变为主要色并放大,长按时恢复默认
            Image(systemName: "checkmark")
                .font(.system(size: isHovered && !isPressing && !didComplete ? 11 : 10, weight: .bold))
                .foregroundStyle(didComplete ? Color.white : (isHovered && !isPressing ? Color.primary : Color.secondary))
        }
        .frame(width: DS.Metrics.completeButtonFrame, height: DS.Metrics.completeButtonFrame)
        .scaleEffect(isPressing && !reduceMotion ? 0.92 : 1)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .animation(DS.Anim.hover, value: isHovered)
        .animation(DS.Anim.hover, value: isPressing)
        .onLongPressGesture(
            minimumDuration: DS.Anim.holdToComplete,
            maximumDistance: 12,
            pressing: { handlePressing($0) },
            perform: { triggerComplete() }
        )
        .help("长按完成")
        .accessibilityLabel("标记完成")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { triggerComplete() }
    }

    /// 按下:环随 holdToComplete 线性填满;中途松手:快速回抽(防误触)。已完成则不回抽。
    private func handlePressing(_ pressing: Bool) {
        withAnimation(DS.Anim.hover) { isPressing = pressing }
        guard !didComplete else { return }
        if pressing {
            withAnimation(.linear(duration: DS.Anim.holdToComplete)) { progress = 1 }
        } else {
            withAnimation(.easeOut(duration: DS.Anim.ringCancel)) { progress = 0 }
        }
    }

    /// 按满 / 无障碍触发:震一下 + 填绿,再通知上层从快照剔除(乐观更新)。
    private func triggerComplete() {
        guard !didComplete else { return }
        didComplete = true
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(DS.Anim.hover) { progress = 1 }
        action()
    }
}

// MARK: - 折叠提示

/// 超出展示上限时的弱化提示行,如「还有 2 个待办」
struct OverflowLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Fonts.overflow)
            .foregroundStyle(.tertiary)
            .padding(.leading, DS.Metrics.rowPaddingH + DS.Metrics.orbFrame + DS.Metrics.rowSpacing)
            .padding(.vertical, 2)
    }
}

// MARK: - 文本清洗

private extension String {
    /// 去首尾空白;空串归为 nil,便于 `if let` 直接决定是否渲染
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Preview

#Preview("会话列表") {
    VStack(alignment: .leading, spacing: 2) {
        FocusTodoCard(session: .mockTodo, onOpen: {}, onComplete: {}, onCreateFilter: {})
            .padding(.bottom, DS.Metrics.focusCardGap)
        TodoRow(session: .mockTodo2, onComplete: {}, onCreateFilter: {})
        OverflowLabel(text: "还有 2 个待办")
        Divider()
        RunningRow(session: .mockRunning)
    }
    .padding(DS.Metrics.panelPadding)
    .frame(width: DS.Metrics.listWidth)
    .background(.background)
}

// MARK: - Mock

extension CodexSessionSummary {
    static var mockTodo: CodexSessionSummary {
        CodexSessionSummary(
            id: "todo-1",
            filePath: "/tmp/rollout-a.jsonl",
            cwd: "/Users/dev/workspace/agent-inbox",
            startedAt: Date().addingTimeInterval(-1800),
            modifiedAt: Date().addingTimeInterval(-180),
            taskCompletedAt: Date().addingTimeInterval(-180),
            lastAgentMessage: "审计完了,基于本机 codex-cli 0.142.5。已执行 features disable external_migration,当前核心功能均已开启。",
            firstPrompt: "帮我审计本机 codex-cli 的配置,顺便把外部迁移特性关掉"
        )
    }

    static var mockTodo2: CodexSessionSummary {
        CodexSessionSummary(
            id: "todo-2",
            filePath: "/tmp/rollout-b.jsonl",
            cwd: "/Users/dev/workspace/_all_do",
            startedAt: Date().addingTimeInterval(-7200),
            modifiedAt: Date().addingTimeInterval(-3600),
            taskCompletedAt: Date().addingTimeInterval(-3600),
            lastAgentMessage: "完成了依赖升级。",
            firstPrompt: "把所有依赖升级到最新"
        )
    }

    static var mockRunning: CodexSessionSummary {
        CodexSessionSummary(
            id: "run-1",
            filePath: "/tmp/rollout-c.jsonl",
            cwd: "/Users/dev/workspace/side-project",
            startedAt: Date().addingTimeInterval(-154),
            modifiedAt: Date(),
            taskCompletedAt: nil,
            lastAgentMessage: nil,
            firstPrompt: "重构支付模块"
        )
    }
}
