import AppKit
import SwiftUI
import Testing
@testable import AgentInboxApp

@MainActor
@Suite("Note background")
struct NoteBackgroundTests {
    @Test("an idle transparent note fades foreground and background together")
    func idleTransparentNote() throws {
        let pixels = try renderedPixels(isActive: false)
        #expect(abs(pixels.foreground - 0.2) < 0.02)
        #expect(abs(pixels.background - 0.2) < 0.02)
    }

    @Test("an active transparent note has an opaque reading surface")
    func activeTransparentNote() throws {
        let pixels = try renderedPixels(isActive: true)
        #expect(pixels.foreground == 1)
        #expect(pixels.background == 1)
    }

    private func renderedPixels(isActive: Bool) throws -> (foreground: CGFloat, background: CGFloat) {
        let renderer = ImageRenderer(content:
            Color.black
                .frame(width: 8, height: 8)
                .frame(width: 20, height: 20)
                .modifier(NoteBackground(color: .yellow, material: .transparent, isActive: isActive))
        )
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let foreground = try #require(bitmap.colorAt(x: 10, y: 10))
        let background = try #require(bitmap.colorAt(x: 2, y: 2))
        return (foreground.alphaComponent, background.alphaComponent)
    }
}
