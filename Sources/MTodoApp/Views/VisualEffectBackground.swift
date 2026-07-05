import AppKit
import SwiftUI

/// 系统真材质背景 —— 直接桥接 NSVisualEffectView
/// V3 用「windowBackgroundColor(0.8) 叠 ultraThinMaterial(0.5)」调出的是浑浊的灰;
/// 正确做法是 behindWindow 混合的原生 vibrancy,和系统菜单/弹窗同一质感。
struct VisualEffectBackground: NSViewRepresentable {
    /// 材质风格:.popover 明暗自适应,观感最接近系统原生浮层
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        // behindWindow:对窗口背后的桌面/其他窗口取样模糊(真毛玻璃的关键)
        view.blendingMode = .behindWindow
        // 始终保持活跃取样,不随 app 失焦变成死灰
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
