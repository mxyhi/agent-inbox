import SwiftUI

/// 完成反馈图标 —— 待办完成时在按钮上方弹出的绿色 ✓，快速淡入放大后消失
/// 纯视觉反馈，不阻塞交互，配合震动与按钮填绿形成完整的完成确认。
struct CompletionFeedback: View {
    /// 触发标记：外部翻转此值触发一次动画
    let trigger: Bool

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.5
    @State private var offset: CGFloat = 0

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(DS.Colors.done)
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(y: offset)
            .onChange(of: trigger) { _, _ in
                playAnimation()
            }
    }

    /// 播放完成反馈动画：淡入 + 放大 + 上浮 + 淡出
    private func playAnimation() {
        // 重置状态
        opacity = 0
        scale = 0.5
        offset = 0

        // 阶段1：快速淡入放大（0.15s）
        withAnimation(.easeOut(duration: 0.15)) {
            opacity = 1
            scale = 1
        }

        // 阶段2：短暂停留 + 开始上浮（0.15s 后开始）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.3)) {
                offset = -8
            }
        }

        // 阶段3：淡出（0.25s 后开始，持续 0.2s）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeIn(duration: 0.2)) {
                opacity = 0
            }
        }
    }
}

// MARK: - Preview

#Preview("完成反馈") {
    struct PreviewContainer: View {
        @State private var trigger = false

        var body: some View {
            VStack(spacing: 40) {
                Button("触发反馈") {
                    trigger.toggle()
                }

                ZStack {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 28, height: 28)

                    CompletionFeedback(trigger: trigger)
                }
            }
            .padding(40)
            .frame(width: 300, height: 200)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    return PreviewContainer()
}
