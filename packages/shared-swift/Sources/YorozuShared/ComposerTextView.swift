#if os(iOS)
    import SwiftUI
    import UIKit

    /// The phone's message field. SwiftUI's `TextField` offers Paste only for text, so an image
    /// on the pasteboard could reach the composer only through the + menu; this is a
    /// `UITextView` that takes the edit menu's Paste and ⌘V for images too.
    struct ComposerTextView: UIViewRepresentable {
        @Binding var text: String
        let placeholder: String
        let onSubmit: (Bool) -> Void
        let onSendNextQueued: () -> Bool
        let onQuestionOption: (Int) -> Bool
        let onPromptHistory: (Bool) -> Bool
        /// Called when Paste finds an image; nil while images cannot be attached, so Paste goes
        /// back to being text-only.
        let onPasteImage: (() -> Void)?
        /// The thread to take the keyboard for, once each: a thread just started. Nil leaves
        /// focus wherever it is.
        var focusThread: String?

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
            view.placeholderLabel.text = placeholder
            view.placeholderLabel.isHidden = !text.isEmpty
            view.onSubmit = onSubmit
            view.onSendNextQueued = onSendNextQueued
            view.onQuestionOption = onQuestionOption
            view.onPromptHistory = onPromptHistory
            view.onPasteImage = onPasteImage
            if focusThread != view.focusThread {
                view.focusThread = focusThread
                if focusThread != nil { view.focus() }
            }
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

            func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
                guard textView.text.isEmpty, range.length == 0, textView.markedTextRange == nil,
                      replacement.count == 1, let number = Int(replacement), (1...9).contains(number)
                else { return true }
                return !((textView as? PastingTextView)?.onQuestionOption(number) ?? false)
            }
        }
    }

    final class PastingTextView: UITextView {
        let placeholderLabel = UILabel()
        var onSubmit: (Bool) -> Void = { _ in }
        var onSendNextQueued: () -> Bool = { false }
        var onQuestionOption: (Int) -> Bool = { _ in false }
        var onPromptHistory: (Bool) -> Bool = { _ in false }
        var onPasteImage: (() -> Void)?
        var focusThread: String?
        private var focusPending = false

        /// A view not yet in a window cannot be first responder, so the request waits for one.
        func focus() {
            if window == nil { focusPending = true } else { becomeFirstResponder() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, focusPending else { return }
            focusPending = false
            becomeFirstResponder()
        }

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
            if let key = presses.first?.key, key.keyCode == .keyboardReturnOrEnter, markedTextRange == nil {
                let modifiers = key.modifierFlags.intersection([.shift, .control, .alternate, .command])
                if modifiers == [.command, .shift], onSendNextQueued() { return }
                if !modifiers.contains(.shift) { return onSubmit(modifiers == .command) }
            }
            if let key = presses.first?.key, markedTextRange == nil,
                key.modifierFlags.intersection([.shift, .control, .alternate, .command]).isEmpty,
                key.keyCode == .keyboardUpArrow || key.keyCode == .keyboardDownArrow,
                onPromptHistory(key.keyCode == .keyboardUpArrow)
            {
                return
            }
            super.pressesBegan(presses, with: event)
        }
    }
#elseif os(macOS)
    import AppKit
    import SwiftUI

    /// Which key-down in the Mac's message field is the send key: Return or the keypad's
    /// Enter with exactly `sendModifiers` held. The caller also checks ⌘ for alternate delivery
    /// and ⌘⇧ for Send now. Not while an input method is composing:
    /// that Return confirms the conversion and must reach the field.
    func isSendKey(
        keyCode: UInt16, flags: NSEvent.ModifierFlags, sendModifiers: NSEvent.ModifierFlags, composing: Bool
    ) -> Bool {
        guard !composing, keyCode == 36 || keyCode == 76 else { return false }
        // The keypad's Enter arrives flagged as such; only the modifier keys matter.
        return flags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == sendModifiers
    }

    enum ComposerSendAction: Equatable { case send(alternate: Bool), sendNextQueued }

    /// What an Enter in the Mac's message field does. ⌘⇧ Enter sends the next queued message
    /// now; Mod+Enter flips delivery for one message, adding ⌥ when ⌘ Enter is already the
    /// send key, so choosing ⌘ Enter to send never changes how messages are delivered.
    func composerSendAction(
        keyCode: UInt16, flags: NSEvent.ModifierFlags, sendModifiers: NSEvent.ModifierFlags, composing: Bool
    ) -> ComposerSendAction? {
        if isSendKey(keyCode: keyCode, flags: flags, sendModifiers: [.command, .shift], composing: composing) {
            return .sendNextQueued
        }
        let flip: NSEvent.ModifierFlags = sendModifiers.contains(.command) ? [.command, .option] : .command
        if isSendKey(keyCode: keyCode, flags: flags, sendModifiers: flip, composing: composing) {
            return .send(alternate: true)
        }
        return isSendKey(keyCode: keyCode, flags: flags, sendModifiers: sendModifiers, composing: composing)
            ? .send(alternate: false) : nil
    }

    /// What a key means to the skill picker while it is open.
    enum SkillPickerKey: Equatable { case up, down, select, dismiss }

    /// The picker's keys: the arrows, Return or Tab to pick, Escape to close. Only unmodified,
    /// so ⌘Return still sends and ⇧Tab still moves focus, and not while an input method is
    /// composing, whose arrows and Return choose a conversion.
    func skillPickerKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, composing: Bool) -> SkillPickerKey? {
        guard !composing,
            flags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty
        else { return nil }
        return switch keyCode {
        case 126: .up
        case 125: .down
        case 36, 76, 48: .select
        case 53: .dismiss
        default: nil
        }
    }

    /// The Mac message field's keys that the field must not get. The field is AppKit's text
    /// editor, which handles its keys below the pipeline SwiftUI delivers key presses through:
    /// a key equivalent on the send button and a SwiftUI paste command both go unseen. This
    /// sees the keystroke before the window does and lets it through unless it is the send key
    /// with something to send — see ``isSendKey`` — or ⌘V with an image on the pasteboard.
    /// `onPaste` is nil while images cannot be attached, and Paste is text-only again.
    struct ComposerKeyMonitor: NSViewRepresentable {
        let isActive: Bool
        let sendModifiers: NSEvent.ModifierFlags
        /// Returns whether a message went. An Enter with nothing to send reaches the field.
        let onSend: (Bool) -> Bool
        let onSendNextQueued: () -> Bool
        let onPaste: (() -> Void)?
        /// Set while the skill picker is open, which then has its keys before Send and Stop do.
        let onPickerKey: ((SkillPickerKey) -> Void)?
        let onQuestionOption: (Int) -> Bool
        let onPromptHistory: (Bool) -> Bool

        func makeNSView(context: Context) -> MonitorView { MonitorView() }

        func updateNSView(_ view: MonitorView, context: Context) {
            view.isActive = isActive
            view.sendModifiers = sendModifiers
            view.onSend = onSend
            view.onSendNextQueued = onSendNextQueued
            view.onPaste = onPaste
            view.onPickerKey = onPickerKey
            view.onQuestionOption = onQuestionOption
            view.onPromptHistory = onPromptHistory
        }

        final class MonitorView: NSView {
            var isActive = false
            var sendModifiers: NSEvent.ModifierFlags = []
            var onSend: (Bool) -> Bool = { _ in false }
            var onSendNextQueued: () -> Bool = { false }
            var onPaste: (() -> Void)?
            var onPickerKey: ((SkillPickerKey) -> Void)?
            var onQuestionOption: (Int) -> Bool = { _ in false }
            var onPromptHistory: (Bool) -> Bool = { _ in false }
            private var monitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // Only this window's field: every open chat has its own monitor.
                    guard let self, self.isActive, event.window === self.window else { return event }
                    let composing = (self.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
                    if let onPickerKey = self.onPickerKey,
                        let key = skillPickerKey(
                            keyCode: event.keyCode, flags: event.modifierFlags, composing: composing)
                    {
                        onPickerKey(key)
                        return nil
                    }
                    if let key = skillPickerKey(
                        keyCode: event.keyCode, flags: event.modifierFlags, composing: composing),
                        key == .up || key == .down, self.onPromptHistory(key == .up)
                    {
                        return nil
                    }
                    if !composing,
                        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                            .subtracting([.numericPad, .function]).isEmpty,
                        let characters = event.characters, characters.count == 1,
                        let number = Int(characters), (1...9).contains(number),
                        self.onQuestionOption(number)
                    {
                        return nil
                    }
                    switch composerSendAction(keyCode: event.keyCode, flags: event.modifierFlags,
                        sendModifiers: self.sendModifiers, composing: composing) {
                    case .sendNextQueued: if self.onSendNextQueued() { return nil }
                    case .send(let alternate): if self.onSend(alternate) { return nil }
                    case nil: break
                    }
                    if let onPaste = self.onPaste,
                        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                        event.charactersIgnoringModifiers == "v", pasteboardHasImages()
                    {
                        onPaste()
                        return nil
                    }
                    return event
                }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
#endif
