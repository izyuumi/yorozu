#if os(iOS)
    import SwiftUI
    import UIKit

    /// The phone's message field. SwiftUI's `TextField` offers Paste only for text, so an image
    /// on the pasteboard could reach the composer only through the + menu; this is a
    /// `UITextView` that takes the edit menu's Paste and ⌘V for images too.
    struct ComposerTextView: UIViewRepresentable {
        @Binding var text: String
        let placeholder: String
        let onSubmit: () -> Void
        /// Called when Paste finds an image; nil while images cannot be attached, so Paste goes
        /// back to being text-only.
        let onPasteImage: (() -> Void)?

        private static let maxLines: CGFloat = 6

        func makeUIView(context: Context) -> PastingTextView {
            let view = PastingTextView()
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

        func updateUIView(_ view: PastingTextView, context: Context) {
            context.coordinator.text = $text
            if view.text != text { view.text = text }
            view.placeholderLabel.isHidden = !text.isEmpty
            view.onSubmit = onSubmit
            view.onPasteImage = onPasteImage
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: PastingTextView, context: Context) -> CGSize? {
            guard let width = proposal.width, let font = uiView.font else { return nil }
            let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let maxHeight = ceil(font.lineHeight * Self.maxLines)
            // Grows with the text up to six lines, then scrolls inside, as the TextField did.
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

    final class PastingTextView: UITextView {
        let placeholderLabel = UILabel()
        var onSubmit: () -> Void = {}
        var onPasteImage: (() -> Void)?

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            // `hasImages` only asks; it does not read, so showing the menu raises no banner.
            if action == #selector(paste(_:)), onPasteImage != nil, pasteboardHasImages() {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            guard let onPasteImage, pasteboardHasImages() else { return super.paste(sender) }
            onPasteImage()
        }

        /// A hardware keyboard's Return sends; Shift-Return is a new line.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if let key = presses.first?.key, key.keyCode == .keyboardReturnOrEnter,
                !key.modifierFlags.contains(.shift)
            {
                return onSubmit()
            }
            super.pressesBegan(presses, with: event)
        }
    }
#elseif os(macOS)
    import AppKit
    import SwiftUI

    /// ⌘V for an image in the Mac's message field. The field is AppKit's text editor, which takes
    /// every Paste itself and does nothing with an image, so a SwiftUI paste command never
    /// fires; this sees the keystroke first, and lets it through unless there is an image.
    struct ImagePasteMonitor: NSViewRepresentable {
        let isActive: Bool
        let onPaste: () -> Void

        func makeNSView(context: Context) -> MonitorView { MonitorView() }

        func updateNSView(_ view: MonitorView, context: Context) {
            view.isActive = isActive
            view.onPaste = onPaste
        }

        final class MonitorView: NSView {
            var isActive = false
            var onPaste: () -> Void = {}
            private var monitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // Only this window's field: every open chat has its own monitor.
                    guard let self, self.isActive, event.window === self.window,
                        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                        event.charactersIgnoringModifiers == "v", pasteboardHasImages()
                    else { return event }
                    self.onPaste()
                    return nil
                }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
#endif
