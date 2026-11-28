import AppKit
import QuartzCore
import SwiftUI

/// 持续脉冲的 SF Symbol，动画交给 Core Animation 渲染服务（WindowServer）逐帧插值，主线程不参与。
///
/// 为什么不用 `.symbolEffect(.pulse, options: .repeating)`：SwiftUI 的无限动画每一帧都在主线程更新视图图、
/// 重新布局整个 NSHostingView 并重绘文字。120Hz 屏上 6 个运行中会话时收件箱常驻约 43% CPU；
/// 最小基准里同样 6 行，SwiftUI 脉冲 17.7%，CA 图层动画 0.5%。
///
/// 布局仍由一个隐藏的 SwiftUI `Image` 负责，尺寸与 `.firstTextBaseline` 对齐和原来一致，
/// 上面叠一层只负责画、不接点击、不进辅助功能树的 AppKit 视图。
struct PulsingSymbol: View {
    let systemName: String
    let pointSize: CGFloat
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: pointSize, weight: .regular))
            .hidden()
            .overlay { PulsingSymbolLayer(systemName: systemName, pointSize: pointSize, color: NSColor(color)) }
            .accessibilityHidden(true)
    }
}

private struct PulsingSymbolLayer: NSViewRepresentable {
    let systemName: String
    let pointSize: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> PulsingImageView {
        let view = PulsingImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: PulsingImageView, context: Context) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        view.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        view.contentTintColor = color
    }
}

/// 进入窗口时挂上无限透明度动画：图层被换掉或视图换窗口后 CA 动画会丢，所以每次进窗口都重挂。
final class PulsingImageView: NSImageView {
    private static let animationKey = "agent-inbox.pulse"

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        // 尊重「减少动态效果」：静态显示，和系统符号效果的行为一致。
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.animationKey)
    }

    /// 只负责画：点击穿透给 SwiftUI 行（整行点按打开会话）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
