import SwiftUI
import TipKit
import YorozuWire
#if os(macOS)
import AppKit
#endif

/// The picker's entries: the quick emoji, the current one if it is not among them, and More… for the system picker.
struct ReactionChoices: View {
    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    let current: String?
    let onReact: (String) -> Void
    let onMore: () -> Void

    var body: some View {
        if let current, !Self.quick.contains(current) { choice(current) }
        ForEach(Self.quick, id: \.self, content: choice)
        Button(String(localized: "More…"), systemImage: "face.smiling", action: onMore)
    }

    private func choice(_ emoji: String) -> some View {
        Button {
            ReactTip().invalidate(reason: .actionPerformed)
            onReact(emoji)
        } label: {
            if emoji == current { Label(emoji, systemImage: "checkmark") } else { Text(emoji) }
        }
    }
}

/// The reactions on a bubble; yours is a button that takes it back.
struct ReactionChips: View {
    let reactions: Reactions
    let onReact: ((String) -> Void)?

    var body: some View {
        HStack(spacing: LayoutMetrics.tight) {
            if let agent = reactions.agent {
                chip(agent, mine: false).accessibilityLabel(Text("Agent reacted \(agent)"))
            }
            if let user = reactions.user {
                Button { onReact?(user) } label: { chip(user, mine: true) }
                    .buttonStyle(.plain)
                    .disabled(onReact == nil)
                    .help(String(localized: "Remove Reaction"))
                    .accessibilityLabel(Text("You reacted \(user)"))
            }
        }
    }

    private func chip(_ emoji: String, mine: Bool) -> some View {
        Text(emoji)
            .textStyle(.subheadline)
            .padding(.horizontal, LayoutMetrics.inner)
            .padding(.vertical, LayoutMetrics.hair)
            .background(mine ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(Color(.secondarySystemBackground)), in: Capsule())
    }
}

/// Any emoji, from the system's own picker: the emoji keyboard on iPhone and iPad, the Character Viewer on the Mac.
struct EmojiSheet: View {
    let onPick: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmojiField(text: $text)
                .padding(LayoutMetrics.gutter)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle(String(localized: "Choose an Emoji"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                }
        }
        .presentationDetents([.medium])
        .onChange(of: text) {
            guard let emoji = text.first(where: \.isEmoji) else { return }
            onPick(String(emoji))
            dismiss()
        }
    }
}

private extension Character {
    var isEmoji: Bool {
        guard let first = unicodeScalars.first?.properties else { return false }
        return first.isEmojiPresentation || (first.isEmoji && unicodeScalars.count > 1)
    }
}

#if os(macOS)
private struct EmojiField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(String(localized: "Emoji"), text: $text)
            .textStyle(.title)
            .focused($focused)
            .task {
                focused = true
                await Task.yield()
                NSApp.orderFrontCharacterPalette(nil)
            }
    }
}
#else
private struct EmojiField: UIViewRepresentable {
    @Binding var text: String

    /// Opens on the emoji keyboard when the user has it enabled.
    final class Field: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.placeholder = String(localized: "Emoji")
        field.font = .preferredFont(forTextStyle: .largeTitle)
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = .center
        field.addAction(UIAction { [weak field] _ in text = field?.text ?? "" }, for: .editingChanged)
        Task { @MainActor in field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: Field, context: Context) {}
}
#endif
