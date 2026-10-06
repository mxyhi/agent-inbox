import SwiftUI

/// 常驻浮窗用静态颜色表达状态，避免每个光点的永久动画持续唤醒布局与渲染。
/// 状态语义由行的文字和 accessibility 提供，运行时长仍按秒更新。
struct StatusOrb: View {
    enum Kind {
        case running
        case todo
        case idle
    }

    let kind: Kind

    private var color: Color {
        switch kind {
        case .running: DS.Colors.running
        case .todo: DS.Colors.todo
        case .idle: DS.Colors.idle
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: DS.Metrics.orbSize, height: DS.Metrics.orbSize)
            .frame(width: DS.Metrics.orbFrame, height: DS.Metrics.orbFrame)
            .accessibilityHidden(true)
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
