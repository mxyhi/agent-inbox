import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Helpers for a task's pasted image — pure CoreGraphics/ImageIO (no AppKit, no database), so
/// `NoteController` stays AppKit-free and all of this is unit-testable in isolation.
///
/// A crop is a **normalised** rect (0…1) with a **top-left** origin — the same orientation as CGImage
/// pixel space, so it maps straight onto `CGImage.cropping(to:)` with no flip. The original bytes are
/// always what's stored; cropping only ever changes this rect, so it can be reset.
enum TaskImage {
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Smallest crop side, as a fraction of the image, so a handle can't collapse the crop to nothing.
    static let minCropSide: CGFloat = 0.1

    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
    }

    /// `crop` with `corner` dragged by `delta` (normalised). The opposite corner stays put; the dragged
    /// one is clamped to the image and kept at least `minCropSide` from the opposite edges.
    static func dragging(_ crop: CGRect, corner: Corner, by delta: CGSize) -> CGRect {
        var (minX, minY, maxX, maxY) = (crop.minX, crop.minY, crop.maxX, crop.maxY)
        if corner.isLeading {
            minX = min(max(minX + delta.width, 0), maxX - minCropSide)
        } else {
            maxX = max(min(maxX + delta.width, 1), minX + minCropSide)
        }
        if corner.isTop {
            minY = min(max(minY + delta.height, 0), maxY - minCropSide)
        } else {
            maxY = max(min(maxY + delta.height, 1), minY + minCropSide)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `crop` slid by `delta` (normalised) at the same size, kept inside the image.
    static func moving(_ crop: CGRect, by delta: CGSize) -> CGRect {
        var moved = crop
        moved.origin.x = min(max(crop.minX + delta.width, 0), 1 - crop.width)
        moved.origin.y = min(max(crop.minY + delta.height, 0), 1 - crop.height)
        return moved
    }

    // ponytail: stored at full size; downscale in normalizedData if big pastes bloat the database.

    /// Pasted bytes → what gets stored: a PNG as-is, anything else ImageIO reads (clipboard TIFF, a
    /// JPEG/HEIC file…) re-encoded as PNG with its EXIF orientation applied. `nil` if it isn't an image.
    static func normalizedData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { return data }
        return decode(source, maxPixelSize: nil).flatMap(pngData)
    }

    /// A downsampled bitmap for drawing on the note. Rows re-render on every frame of a drag, so the
    /// note only ever draws this — never the full-size image.
    static func thumbnail(_ data: Data, maxPixelSize: Int = 1024) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { decode($0, maxPixelSize: maxPixelSize) }
    }

    /// The size of an image with `aspect` (width ÷ height) fit within `maxWidth` × `maxHeight`.
    static func fittedSize(aspect: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard aspect > 0 else { return .zero }
        return aspect * maxHeight > maxWidth
            ? CGSize(width: maxWidth, height: maxWidth / aspect)
            : CGSize(width: aspect * maxHeight, height: maxHeight)
    }

    /// The whole image at full resolution with its orientation applied — for the image window.
    static func fullImage(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { decode($0, maxPixelSize: nil) }
    }

    /// `image` cropped to the normalised `crop`.
    static func cropped(_ image: CGImage, to crop: CGRect) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pixels = CGRect(
            x: crop.minX * width, y: crop.minY * height,
            width: crop.width * width, height: crop.height * height
        )
        return image.cropping(to: pixels.integral)
    }

    /// Writes the cropped image to a temp PNG for the Preview app and returns its URL. Each call
    /// clears earlier previews and uses a fresh folder, so a re-crop can never show a stale cached file.
    static func writePreviewFile(_ data: Data, crop: CGRect) -> URL? {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("TicPreviews", isDirectory: true)
        let png = crop == fullCrop
            ? data   // stored data is already PNG (normalizedData)
            : CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { decode($0, maxPixelSize: nil) }
                .flatMap { cropped($0, to: crop) }
                .flatMap(pngData)
        guard let png else { return nil }
        do {
            try? fileManager.removeItem(at: root)
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Image.png")
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Decodes the first frame with its orientation applied; a `nil` `maxPixelSize` keeps full size.
    private static func decode(_ source: CGImageSource, maxPixelSize: Int?) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
