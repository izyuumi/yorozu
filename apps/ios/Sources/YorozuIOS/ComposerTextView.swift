import SwiftUI
import UIKit

// The iOS half of v1 packages/shared-swift ComposerTextView.swift, without image paste, question
// options, prompt history and Send now.

/// The phone's message field: a `UITextView` that grows to five lines, then scrolls inside. The
/// software keyboard's Return is a new line; a hardware keyboard has smart Enter (see
/// `ComposerUITextView.pressesBegan`).
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    private static let maxLines: CGFloat = 5

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
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let maxHeight = ceil(font.lineHeight * Self.maxLines)
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
