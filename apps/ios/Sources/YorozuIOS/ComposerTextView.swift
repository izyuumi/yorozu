import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import AppKit

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    var onFiles: ([URL]) -> Bool = { _ in false }
    var onImages: ([Data]) -> Bool = { _ in false }
    var onPasteData: (Data, String, String) -> Bool = { _, _, _ in false }
    var cursor: ComposerCursor?

    @Environment(\.textZoom) private var zoom

    private static let maxLines: CGFloat = 5

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = ComposerNSTextView()
        view.delegate = context.coordinator
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
        view.takeImages = onImages
        let font = NSFont.preferred(.body, zoom: zoom)
        if view.font != font {
            view.font = font
            view.needsDisplay = true
        }
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.needsDisplay = true
        }
        context.coordinator.cursor = cursor
        if let range = cursor?.take(within: (view.string as NSString).length) { view.setSelectedRange(range) }
        if view.placeholder != placeholder {
            view.placeholder = placeholder
            view.needsDisplay = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let view = scroll.documentView as? NSTextView, let font = view.font,
              let layout = view.layoutManager else { return nil }
        let line = layout.defaultLineHeight(for: font)
        let measured = view.string.hasSuffix("\n") ? view.string + " " : view.string
        let used = NSAttributedString(string: measured, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: min(max(used.height, line), line * Self.maxLines).rounded(.up))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var cursor: ComposerCursor?
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            cursor?.track(view.selectedRange())
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var placeholder = ""
    var submit: () -> Void = {}
    var takeFiles: ([URL]) -> Bool = { _ in false }
    var takeImages: ([Data]) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if modifiers == .command { return submit() }
        // Return sends a one-line message unless the owner opted into ⌘Return; Shift-Return always adds a line.
        if modifiers.isEmpty, !UserDefaults.standard.bool(forKey: CommandReturnSends.key), !string.contains("\n") { return submit() }
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
        if !urls.isEmpty { return takeFiles(urls) }
        let images = pasteboard.pasteboardItems?.compactMap { $0.data(forType: .png) ?? $0.data(forType: .tiff) } ?? []
        return !images.isEmpty && takeImages(images)
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
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    var onFiles: ([URL]) -> Bool = { _ in false }
    var onImages: ([Data]) -> Bool = { _ in false }
    var onPasteData: (Data, String, String) -> Bool = { _, _, _ in false }
    var cursor: ComposerCursor?

    @Environment(\.dynamicTypeSize) private var typeSize

    private static let maxLines: CGFloat = 5
    private static let measuredLimit = 1_000

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.accessibilityLabel = String(localized: "Message")
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let label = view.placeholderLabel
        label.text = placeholder
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
        let font = UIFont.preferred(.body, size: typeSize)
        if view.font != font {
            view.font = font
            view.placeholderLabel.font = font
        }
        if view.text != text { view.text = text }
        context.coordinator.cursor = cursor
        if let range = cursor?.take(within: (view.text as NSString).length) { view.selectedRange = range }
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
        view.onSubmit = onSubmit
        view.takeFiles = onFiles
        view.takeImages = onImages
        view.takeData = onPasteData
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let font = uiView.font else { return nil }
        let maxHeight = ceil(font.lineHeight * Self.maxLines)
        if (uiView.text as NSString).length > Self.measuredLimit { return CGSize(width: width, height: maxHeight) }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(max(fit.height, ceil(font.lineHeight)), maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var cursor: ComposerCursor?
        init(text: Binding<String>) { self.text = text }

        func textViewDidChangeSelection(_ textView: UITextView) { cursor?.track(textView.selectedRange) }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            DispatchQueue.main.async { textView.scrollRangeToVisible(textView.selectedRange) }
        }
    }
}

final class ComposerUITextView: UITextView {
    let placeholderLabel = UILabel()
    var onSubmit: () -> Void = {}
    var takeFiles: ([URL]) -> Bool = { _ in false }
    var takeImages: ([Data]) -> Bool = { _ in false }
    var takeData: (Data, String, String) -> Bool = { _, _, _ in false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs
            || UIPasteboard.general.itemProviders.contains(where: { Self.fileType(in: $0) != nil }) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        let urls = board.urls?.filter(\.isFileURL) ?? []
        if !urls.isEmpty, takeFiles(urls) { return }
        let images = board.images?.compactMap { $0.jpegData(compressionQuality: 0.9) } ?? []
        if !images.isEmpty, takeImages(images) { return }
        var loading = false
        for provider in board.itemProviders {
            guard let type = Self.fileType(in: provider) else { continue }
            loading = true
            let name = provider.suggestedName ?? "Pasted file"
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if type.conforms(to: .image) { _ = self.takeImages([data]) }
                    else {
                        let fileName = (name as NSString).pathExtension.isEmpty
                            ? "\(name).\(type.preferredFilenameExtension ?? "bin")" : name
                        _ = self.takeData(data, fileName, type.preferredMIMEType ?? "application/octet-stream")
                    }
                }
            }
        }
        if !loading { super.paste(sender) }
    }

    private static func fileType(in provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        guard !types.contains(where: { $0.conforms(to: .text) }) else { return nil }
        return types.first {
            $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url)
        }
    }

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

/// The composer's caret, kept outside the text view so dictated text lands where the caret was, even though
/// the voice bar replaced the text view meanwhile; a second dictation goes after the first.
final class ComposerCursor {
    private var range: NSRange?
    private var pending = false

    func track(_ range: NSRange) {
        if !pending { self.range = range }
    }

    /// The caret to restore after an insertion, once.
    func take(within length: Int) -> NSRange? {
        guard pending, let range, NSMaxRange(range) <= length else { return nil }
        pending = false
        return range
    }

    /// Inserts `piece` at the caret (the end if none), with a space after a Latin word, and moves the caret after it.
    func insert(_ piece: String, into text: inout String) {
        let current = text as NSString
        var at = range ?? NSRange(location: current.length, length: 0)
        if NSMaxRange(at) > current.length { at = NSRange(location: current.length, length: 0) }
        let before = at.location > 0 ? current.substring(with: NSRange(location: at.location - 1, length: 1)).first : nil
        let spaced = if let before, !before.isWhitespace, before.isASCII || piece.first?.isASCII == true { " " + piece } else { piece }
        text = current.replacingCharacters(in: at, with: spaced)
        range = NSRange(location: at.location + (spaced as NSString).length, length: 0)
        pending = true
    }
}
