#if os(macOS)
import AppKit
import SwiftUI
import Testing

@testable import YorozuShared

private actor EditingTransport: ChatTransport {
    func connect() -> AsyncStream<TransportUpdate> { AsyncStream { $0.finish() } }
    func send(_ event: YorozuEvent) {}
    func close() {}
}

/// Exercise the real field, binding and key monitor together, without activating a window.
@Test @MainActor func composerNewlineUsesNativeSelection() async throws {
    _ = NSApplication.shared
    let domain = "ComposerEditingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let model = ChatModel(transport: EditingTransport())
    let thread = model.newDraft()
    model.drafts[thread.id] = "abc"
    model.drafts["other-thread"] = "keep this draft"
    let attachment = MessageAttachment(name: "note.txt", mime: "text/plain", data: Data("note".utf8).base64EncodedString())
    model.attachments[thread.id] = [attachment]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: ChatView(model: model, thread: thread)
        .defaultAppStorage(defaults))
    window.contentView = host
    defer { window.orderOut(nil); model.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    let field = try #require(fields(host).first { $0.stringValue == "abc" })
    #expect(window.makeFirstResponder(field))
    try await Task.sleep(for: .milliseconds(100))
    let editor = try #require(window.firstResponder as? NSTextView)
    func monitors(_ view: NSView) -> [ComposerKeyMonitor.MonitorView] {
        (view as? ComposerKeyMonitor.MonitorView).map { [$0] } ?? view.subviews.flatMap(monitors)
    }
    let monitor = try #require(monitors(host).first)
    try #require(monitor.isActive)

    func press(_ flags: NSEvent.ModifierFlags, keypad: Bool = false) async throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: keypad ? flags.union([.numericPad, .function]) : flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: keypad ? "\u{3}" : "\r", charactersIgnoringModifiers: keypad ? "\u{3}" : "\r",
            isARepeat: false, keyCode: keypad ? 76 : 36))
        // Exercise the same handler installed by the local monitor. NSApplication won't
        // forward unconsumed events to an offscreen, non-key window, so do that here.
        #expect(event.window === window)
        if let forwarded = monitor.handleKeyDown(event) { window.sendEvent(forwarded) }
        try await Task.sleep(for: .milliseconds(50))
    }
    let cases: [(String, NSRange, String)] = [
        ("abc", NSRange(location: 0, length: 0), "\nabc"),
        ("abc", NSRange(location: 1, length: 0), "a\nbc"),
        ("abc", NSRange(location: 3, length: 0), "abc\n"),
        ("abcd", NSRange(location: 1, length: 2), "a\nd"),
        ("a\nb\nc", NSRange(location: 3, length: 0), "a\nb\n\nc"),
        ("a👩🏽‍💻日本b", NSRange(location: 8, length: 2), "a👩🏽‍💻\nb"),
    ]
    for commandReturn in [false, true] {
        defaults.set(commandReturn, forKey: ChatView.sendWithCommandReturnKey)
        for (index, item) in cases.enumerated() {
            let (text, selection, expected) = item
            model.drafts[thread.id] = text
            try await Task.sleep(for: .milliseconds(50))
            editor.setSelectedRange(selection)
            editor.undoManager?.removeAllActions()
            try await press(.shift, keypad: index == 2)
            #expect(model.drafts[thread.id] == expected)
            #expect(editor.string == expected)
            #expect(editor.selectedRange() == NSRange(location: selection.location + 1, length: 0))
            #expect(model.attachments[thread.id] == [attachment])
            #expect(model.outbox.isEmpty)
            #expect(model.drafts["other-thread"] == "keep this draft")
            try await press(.shift)
            let repeated = (expected as NSString).replacingCharacters(in: NSRange(location: selection.location + 1, length: 0), with: "\n")
            #expect(model.drafts[thread.id] == repeated)
            #expect(editor.selectedRange() == NSRange(location: selection.location + 2, length: 0))
            #expect(editor.undoManager?.canUndo == true)
            NSApp.sendAction(Selector(("undo:")), to: window, from: nil)
            try await Task.sleep(for: .milliseconds(50))
            // AppKit can group consecutive typing into one undo operation.
            if editor.string == expected { NSApp.sendAction(Selector(("undo:")), to: window, from: nil) }
            try await Task.sleep(for: .milliseconds(50))
            #expect(editor.string == text)
            // The standalone NSHostingView does not mirror Undo into its binding, even for
            // ordinary typing on the baseline. Assert native editor restoration here.
        }
        if commandReturn {
            model.drafts[thread.id] = "abc"
            try await Task.sleep(for: .milliseconds(50))
            editor.setSelectedRange(NSRange(location: 1, length: 0))
            try await press([])
            #expect(model.drafts[thread.id] == "a\nbc")
            #expect(model.outbox.isEmpty)
        }
    }
    // Return during conversion belongs to the input method, never Send.
    editor.setSelectedRange(NSRange(location: 1, length: 0))
    editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: editor.selectedRange())
    #expect(editor.hasMarkedText())
    try await press(.command)
    #expect(model.outbox.isEmpty)
    editor.unmarkText()

    // The configured send shortcut still sends the edited draft and staged attachment.
    model.drafts[thread.id] = "send this"
    try await Task.sleep(for: .milliseconds(50))
    try await press(.command)
    #expect(model.drafts[thread.id] == "")
    #expect(model.attachments[thread.id] == nil)
    #expect(model.outbox.contains { item in
        guard case .message(let message) = item.event.payload else { return false }
        return message.text == "send this" && message.attachments == [attachment]
    })
    defaults.set(false, forKey: ChatView.sendWithCommandReturnKey)
    model.drafts[thread.id] = "plain return"
    try await Task.sleep(for: .milliseconds(50))
    try await press([])
    #expect(model.drafts[thread.id] == "")
    #expect(model.outbox.contains { item in
        guard case .message(let message) = item.event.payload else { return false }
        return message.text == "plain return"
    })
}
#endif
