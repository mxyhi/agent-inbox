import SwiftUI

/// 状态光点 —— V4 用动效取代文字标签表达状态:
/// - 运行中:蓝点呼吸(缩放 + 光晕,周期 1.8s)
/// - 待办:橙点 + 涟漪扩散(每 2.5s 一圈,召唤注意力)
/// - 空闲:静止灰点
/// 遵守「减少动画」偏好:reduceMotion 时全部退化为静止实心点。
struct StatusOrb: View {
    enum Kind {
        case running
        case todo
        case idle
    }

    let kind: Kind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch kind {
            case .running:
                runningOrb
            case .todo:
                todoOrb
            case .idle:
                staticDot(DS.Colors.idle)
            }
        }
        // 统一占位:涟漪需要向外扩散的余量,固定框避免布局抖动
        .frame(width: DS.Metrics.orbFrame, height: DS.Metrics.orbFrame)
        // 纯装饰元素,状态语义由行的 accessibility 承担
        .accessibilityHidden(true)
    }

    // MARK: - 运行中:呼吸光点

    @ViewBuilder
    private var runningOrb: some View {
        if reduceMotion {
            staticDot(DS.Colors.running)
        } else {
            // phaseAnimator 在 0↔1 间往返,驱动缩放与光晕同步呼吸
            staticDot(DS.Colors.running)
                .phaseAnimator([0.0, 1.0]) { view, phase in
                    view
                        .scaleEffect(0.82 + 0.18 * phase)
                        .shadow(
                            color: DS.Colors.running.opacity(0.30 + 0.35 * phase),
                            radius: 2 + 3 * phase
                        )
                } animation: { _ in
                    .easeInOut(duration: DS.Anim.breathPhase)
                }
        }
    }

    // MARK: - 待办:静点 + 涟漪

    @ViewBuilder
    private var todoOrb: some View {
        if reduceMotion {
            staticDot(DS.Colors.todo)
        } else {
            staticDot(DS.Colors.todo)
                .background(rippleRing)
        }
    }

    /// 涟漪环:扩散淡出 → 瞬间复位 → 静止间歇,keyframeAnimator 精确编排时间轴
    private var rippleRing: some View {
        Circle()
            .stroke(DS.Colors.todo, lineWidth: 1)
            .frame(width: DS.Metrics.orbSize, height: DS.Metrics.orbSize)
            .keyframeAnimator(
                initialValue: RippleState(),
                repeating: true
            ) { view, state in
                view
                    .scaleEffect(state.scale)
                    .opacity(state.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    // 扩散段:1 → 2.6 倍
                    CubicKeyframe(2.6, duration: DS.Anim.rippleExpand)
                    // 瞬间复位(此时透明,肉眼不可见)
                    MoveKeyframe(1.0)
                    // 静止间歇
                    LinearKeyframe(1.0, duration: DS.Anim.rippleRest)
                }
                KeyframeTrack(\.opacity) {
                    // 出现后随扩散淡出
                    LinearKeyframe(0.55, duration: 0.01)
                    LinearKeyframe(0.0, duration: DS.Anim.rippleExpand - 0.01)
                    // 间歇期保持透明
                    LinearKeyframe(0.0, duration: DS.Anim.rippleRest)
                }
            }
    }

    /// 涟漪动画状态载体
    private struct RippleState {
        var scale: Double = 1.0
        var opacity: Double = 0.0
    }

    // MARK: - 基础点

    private func staticDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: DS.Metrics.orbSize, height: DS.Metrics.orbSize)
    }
}

// MARK: - Preview

#Preview("三种光点") {
    HStack(spacing: 24) {
        StatusOrb(kind: .running)
        StatusOrb(kind: .todo)
        StatusOrb(kind: .idle)
    }
    .padding(40)
}
