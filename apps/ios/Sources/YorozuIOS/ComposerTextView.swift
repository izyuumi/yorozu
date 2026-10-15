import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The iOS half of v1 packages/shared-swift ComposerTextView.swift, without image paste, question
// options, prompt history and Send now.

#if os(macOS)
import AppKit

/// The Mac's message field, an `NSTextView` that grows to five lines, then scrolls inside. Return is a new line and
/// ⌘Return sends (owner, 2026-10-09); never while an input method is composing, whose Return confirms the
/// conversion. Files dropped or pasted onto it attach (`onFiles`) instead of inserting their paths.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    var onFiles: ([URL]) -> Bool = { _ in false }

    private static let maxLines: CGFloat = 5

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = ComposerNSTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = .width
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel(String(localized: "Message"))
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerNSTextView else { return }
        context.coordinator.text = $text
        view.submit = onSubmit
        view.takeFiles = onFiles
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.needsDisplay = true
        }
        if view.placeholder != placeholder {
            view.placeholder = placeholder
            view.needsDisplay = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let view = scroll.documentView as? NSTextView,
              let layout = view.layoutManager, let container = view.textContainer, let font = view.font else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: font)
        let height = max(layout.usedRect(for: container).height, line)
        return CGSize(width: width, height: min(height, line * Self.maxLines).rounded(.up))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var placeholder = ""
    var submit: () -> Void = {}
    var takeFiles: ([URL]) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        // Return (36) or the keypad's Enter (76), outside an input method's composition.
        guard event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if modifiers == .command { return submit() }
        // Plain Return, and Shift- or Option-Return: a new line.
        insertNewline(nil)
    }

    override func paste(_ sender: Any?) {
        if !take(.general) { super.paste(sender) }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        take(sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    private func take(_ pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty && takeFiles(urls)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? .preferredFont(forTextStyle: .body), .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y))
    }
}
#else
/// The phone's message field: a `UITextView` that grows to five lines, then scrolls inside. The
/// software keyboard's Return is a new line; a hardware keyboard has smart Enter (see
/// `ComposerUITextView.pressesBegan`).
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    /// The Mac's file drop and paste; on iPhone and iPad a drop lands on the conversation instead.
    var onFiles: ([URL]) -> Bool = { _ in false }

    private static let maxLines: CGFloat = 5
    /// UTF-16 units past which the text cannot fit in `maxLines`.
    private static let measuredLimit = 1_000

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.accessibilityLabel = String(localized: "Message")
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let label = view.placeholderLabel
        label.text = placeholder
        label.font = view.font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .placeholderText
        label.isAccessibilityElement = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ])
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text { view.text = text }
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
        view.onSubmit = onSubmit
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let font = uiView.font else { return nil }
        let maxHeight = ceil(font.lineHeight * Self.maxLines)
        // Far more text than five lines hold, even on an iPad at the smallest size: at the cap without measuring. Laying
        // out a large paste in full, on each of SwiftUI's many proposals, took seconds.
        if (uiView.text as NSString).length > Self.measuredLimit {
            uiView.isScrollEnabled = true
            return CGSize(width: width, height: maxHeight)
        }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // Grows with the text up to five lines, then scrolls inside, as the TextField did.
        uiView.isScrollEnabled = fit.height > maxHeight
        return CGSize(width: width, height: min(max(fit.height, ceil(font.lineHeight)), maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

final class ComposerUITextView: UITextView {
    let placeholderLabel = UILabel()
    var onSubmit: () -> Void = {}

    /// Smart Enter on a hardware keyboard: Return sends while the draft is one line; once it has a
    /// line break (Shift-Return or a paste), Return is a new line and ⌘Return sends. Shift-Return is
    /// always a new line. Not while an input method is composing (`markedTextRange`): that Return
    /// confirms the conversion and must reach the field.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key, key.keyCode == .keyboardReturnOrEnter, markedTextRange == nil {
            let flags = key.modifierFlags
            if flags.contains(.command) || (!flags.contains(.shift) && !text.contains("\n")) {
                return onSubmit()
            }
        }
        super.pressesBegan(presses, with: event)
    }
}
#endif
