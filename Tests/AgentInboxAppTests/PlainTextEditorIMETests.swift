import AppKit
import SwiftUI
import Testing
@testable import AgentInboxApp

/// Return during IME composition (e.g. Pinyin) belongs to the input method — it commits the raw
/// letters — so it must not also fire the editor's commit/submit (GitHub #11).
@MainActor
@Suite("PlainTextEditor IME")
struct PlainTextEditorIMETests {
    private func returnKey() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
    }

    private func makeEditor() -> (EditorTextView, () -> Int) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let editor = EditorTextView()
        _ = editor.layoutManager
        editor.isEditable = true
        window.contentView = editor
        window.makeFirstResponder(editor)
        var submits = 0
        editor.onSubmit = { submits += 1 }
        return (editor, { submits })
    }

    @Test("Return submits when nothing is being composed")
    func returnSubmits() {
        let (editor, submits) = makeEditor()
        editor.keyDown(with: returnKey())
        #expect(submits() == 1)
    }

    @Test("Return mid-composition is left to the input method")
    func returnDuringCompositionDoesNotSubmit() {
        let (editor, submits) = makeEditor()
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.keyDown(with: returnKey())
        #expect(submits() == 0)
    }

    @Test("a stale text update preserves Pinyin through candidate selection")
    func staleUpdatePreservesComposition() {
        let (editor, submits) = makeEditor()
        var draft = "已有"
        let coordinator = PlainTextEditor.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }), focusRequest: 0
        )
        editor.delegate = coordinator
        editor.string = draft
        editor.setSelectedRange(NSRange(location: draft.utf16.count, length: 0))
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())

        editor.synchronizeText(with: "已有")

        #expect(editor.string == "已有pin")
        #expect(editor.hasMarkedText())

        editor.insertText("拼", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(draft == "已有拼")
        editor.keyDown(with: returnKey())
        #expect(submits() == 1)

        editor.synchronizeText(with: "")
        #expect(editor.string.isEmpty)
    }
}
