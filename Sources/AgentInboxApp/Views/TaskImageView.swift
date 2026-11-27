import AppKit
import SwiftUI

/// A task's pasted image, drawn under its text: the cropped thumbnail, fit to the text column and
/// capped in height so a tall screenshot can't swallow the note. Hover reveals crop / open buttons;
/// double-click opens the image window (zoom, Open in Preview); right-click has the rest.
///
/// **Crop mode** shows the whole image with the discarded area dimmed and a bracket on each corner of
/// the kept area: drag a bracket to resize, drag anywhere else to slide the crop. ⏎ (or click-away)
/// keeps it, ⎋ cancels. The crop is only a normalised rect over the stored original — never destructive.
/// SwiftUI draws crop mode; `CropTrackingView` (AppKit) takes its mouse and keyboard.
struct TaskImageView: View {
    static let maxHeight: CGFloat = 200

    /// The uncropped thumbnail; nil while it's still loading.
    let image: CGImage?
    let crop: CGRect
    let theme: NoteTheme
    var onCrop: (CGRect) -> Void = { _ in }
    /// Opens the image in the image window.
    var onOpen: () -> Void = {}
    var onRemove: () -> Void = {}
    /// Reports when the image starts / stops being pointed at or cropped, so the row can pause its reorder
    /// drag — otherwise dragging a crop handle or pressing a hover button also drags the whole task.
    var onInteractionChange: (Bool) -> Void = { _ in }

    @State private var hovering = false
    /// The crop being edited; non-nil exactly while in crop mode.
    @State private var draftCrop: CGRect?
    // Memoises the cropped bitmap so a re-render (every frame of a drag) reuses the same image.
    @State private var cache = CroppedImageCache()

    var body: some View {
        Group {
            if let image {
                if let draftCrop {
                    cropEditor(image, crop: draftCrop)
                } else if let shown = cache.image(image, crop: crop) {
                    display(shown)
                }
            }
        }
        // While the pointer is on the image or it's being cropped, its row must not start a reorder drag.
        .onChange(of: hovering || draftCrop != nil) { _, active in onInteractionChange(active) }
    }

    // MARK: - Display

    private func display(_ shown: CGImage) -> some View {
        AspectFit(image: shown, maxHeight: Self.maxHeight) {
            Image(decorative: shown, scale: 1).resizable()
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 4) {
                        glyphButton("crop", help: "Crop") { beginCrop() }
                        glyphButton("arrow.up.left.and.arrow.down.right", help: "Open image") { onOpen() }
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .onHover { inside in withAnimation(.easeInOut(duration: 0.12)) { hovering = inside } }
            .onTapGesture(count: 2) { onOpen() }
            .contextMenu {
                Button("Open Image") { onOpen() }
                Divider()
                Button("Crop") { beginCrop() }
                Button("Reset Crop") { onCrop(TaskImage.fullCrop) }
                    .disabled(crop == TaskImage.fullCrop)
                Divider()
                Button("Remove Image", role: .destructive, action: onRemove)
            }
    }

    /// A small glyph on a frosted disc, legible over any picture.
    private func glyphButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Crop mode

    private func cropEditor(_ image: CGImage, crop: CGRect) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            AspectFit(image: image, maxHeight: Self.maxHeight) {
                Image(decorative: image, scale: 1).resizable()
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay { GeometryReader { geo in cropOverlay(crop: crop, size: geo.size) } }

            HStack(spacing: 10) {
                hintButton(glyphs: "⏎", label: "done") { endCrop(save: true) }
                hintButton(glyphs: "⎋", label: "cancel") { endCrop(save: false) }
            }
        }
    }

    /// The dimmed discard area, the kept-area outline and the four corner brackets — drawn only; the
    /// `CropInteraction` laid over them takes every click and key.
    private func cropOverlay(crop: CGRect, size: CGSize) -> some View {
        let box = CGRect(
            x: crop.minX * size.width, y: crop.minY * size.height,
            width: crop.width * size.width, height: crop.height * size.height
        )
        return ZStack {
            Group {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

                Rectangle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)

                ForEach(TaskImage.Corner.allCases, id: \.self) { corner in
                    bracket(corner)
                        .position(x: corner.isLeading ? box.minX : box.maxX, y: corner.isTop ? box.minY : box.maxY)
                }
            }
            .allowsHitTesting(false)

            CropInteraction(
                crop: crop,
                onChange: { draftCrop = $0 },
                onDone: { endCrop(save: true) },
                onCancel: { endCrop(save: false) }
            )
        }
        .frame(width: size.width, height: size.height)
    }

    /// An L-shaped bracket whose vertex sits on the crop corner, arms pointing into the kept area.
    private func bracket(_ corner: TaskImage.Corner) -> some View {
        let side: CGFloat = 22, arm: CGFloat = 10
        let vertex = CGPoint(x: side / 2, y: side / 2)
        return Path { path in
            path.move(to: CGPoint(x: vertex.x + (corner.isLeading ? arm : -arm), y: vertex.y))
            path.addLine(to: vertex)
            path.addLine(to: CGPoint(x: vertex.x, y: vertex.y + (corner.isTop ? arm : -arm)))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
        .shadow(color: .black.opacity(0.4), radius: 1)
        .frame(width: side, height: side)
    }

    /// A shortcut hint that's also clickable, so crop mode can be left with the mouse too.
    private func hintButton(glyphs: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ShortcutHint(glyphs: glyphs, label: label, theme: theme)
        }
        .buttonStyle(.plain)
    }

    private func beginCrop() {
        hovering = false
        draftCrop = crop
    }

    /// Leaves crop mode, saving the draft (⏎, "done", click-away) or discarding it (⎋, "cancel").
    private func endCrop(save: Bool) {
        guard let draft = draftCrop else { return }
        draftCrop = nil   // first, so the focus loss this triggers finds nothing left to save
        if save, draft != crop { onCrop(draft) }
    }
}

/// Lays its content out at `image`'s aspect ratio, fit within the proposed width and `maxHeight`, and
/// reports exactly that size. `.aspectRatio(contentMode: .fit)` + `.frame(maxHeight:)` reported the whole
/// row's width instead, so the hover buttons, hover area and right-click area spread to the note's edge,
/// far from the picture.
struct AspectFit: Layout {
    let image: CGImage
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let aspect = image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 1
        return TaskImage.fittedSize(aspect: aspect, maxWidth: proposal.width ?? .infinity, maxHeight: maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// Caches `image` cropped to `crop`, recomputing only when either actually changes — the cropped
/// `CGImage` is a new object each time, and handing SwiftUI a fresh one every frame would redraw it.
@MainActor
final class CroppedImageCache {
    private var source: CGImage?
    private var crop = CGRect.null
    private var value: CGImage?

    func image(_ image: CGImage, crop: CGRect) -> CGImage? {
        if image === source, crop == self.crop { return value }
        source = image
        self.crop = crop
        value = TaskImage.cropped(image, to: crop)
        return value
    }
}

// MARK: - Crop mode input (AppKit)

/// Hosts `CropTrackingView` over the crop visuals, feeding it the current crop and callbacks.
struct CropInteraction: NSViewRepresentable {
    let crop: CGRect
    let onChange: (CGRect) -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CropTrackingView { CropTrackingView() }

    func updateNSView(_ view: CropTrackingView, context: Context) {
        view.crop = crop
        view.onChange = onChange
        view.onDone = onDone
        view.onCancel = onCancel
    }
}

/// The mouse and keyboard half of crop mode — AppKit, not SwiftUI, on purpose. A SwiftUI `DragGesture`
/// here could miss its mouse-up (the crop kept following the pointer after release, swallowing every
/// later click), and SwiftUI focus never reliably reached the crop view (⏎ / ⎋ / click-away did
/// nothing). AppKit always sends `mouseDragged`/`mouseUp` to the view that got the `mouseDown`, and a
/// first responder gets its keys deterministically — the same reason the task editor is an `NSTextView`.
/// Clicks landing here never reach the row's SwiftUI reorder drag either.
final class CropTrackingView: NSView {
    /// How close (in points) to a corner a press must land to drag that corner rather than slide the crop.
    static let cornerReach: CGFloat = 14

    var crop = TaskImage.fullCrop
    var onChange: (CGRect) -> Void = { _ in }
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}

    /// The drag in progress, from mouse-down to mouse-up.
    private struct Drag {
        let startCrop: CGRect
        let startPoint: CGPoint
        let corner: TaskImage.Corner?   // nil = sliding the whole crop
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }   // top-left origin, matching the normalised crop
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Takes the keyboard as soon as crop mode appears, so ⏎ / ⎋ work without a click first.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        drag = Drag(startCrop: crop, startPoint: point, corner: corner(near: point))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGSize(
            width: (point.x - drag.startPoint.x) / bounds.width,
            height: (point.y - drag.startPoint.y) / bounds.height
        )
        if let corner = drag.corner {
            onChange(TaskImage.dragging(drag.startCrop, corner: corner, by: delta))
        } else {
            onChange(TaskImage.moving(drag.startCrop, by: delta))
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onDone()     // Return, keypad Enter
        case 53: onCancel()       // Escape
        default: super.keyDown(with: event)
        }
    }

    /// Clicking away (another task, the list background) takes first responder elsewhere — keep the crop.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onDone() }
        return resigned
    }

    /// The crop corner within `cornerReach` of `point`, if any.
    private func corner(near point: CGPoint) -> TaskImage.Corner? {
        TaskImage.Corner.allCases.first { corner in
            let x = (corner.isLeading ? crop.minX : crop.maxX) * bounds.width
            let y = (corner.isTop ? crop.minY : crop.maxY) * bounds.height
            return abs(point.x - x) <= Self.cornerReach && abs(point.y - y) <= Self.cornerReach
        }
    }
}
