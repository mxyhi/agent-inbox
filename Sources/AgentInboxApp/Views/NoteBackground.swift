import SwiftUI
import AppKit

/// Draws the note's paper or frosted glass and fades the complete surface when transparency is idle.
struct NoteBackground: ViewModifier {
    let color: NoteColor
    let material: NoteMaterial
    var isActive = true
    /// The note's own corner rounding — only for a rolled-up bar, which has no system window frame to round it.
    var cornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        let opacity = material == .transparent && !isActive ? 0.2 : 1
        content
            .background(fill)
            .compositingGroup()
            .opacity(opacity)
            .animation(.easeInOut(duration: 0.15), value: opacity)
    }

    @ViewBuilder private var fill: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        switch material {
        case .solid, .transparent:
            shape.fill(color.fill)
        case .glass:
            ZStack {
                VisualEffectBackground(material: .popover, blending: .behindWindow, cornerRadius: cornerRadius)
                shape.fill(color.fill.opacity(0.18))   // a hint of the theme over the glass
            }
        }
    }
}

/// Bridges `NSVisualEffectView` so a note window can show frosted, desktop-sampling translucency.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active   // keep the effect visible even when the window isn't key
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = .active
        nsView.maskImage = cornerRadius > 0 ? Self.roundedMask(radius: cornerRadius) : nil
    }

    /// A stretchable rounded-rect mask: the way to round a behind-window effect view (layer masks don't apply).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
