import SwiftUI

/// The approval card: the agent asking permission for one external action. It reads like a
/// system permission prompt rather than a chat bubble, because that is what it is — a request
/// to act on your behalf — and the answers stack the way a permission prompt's do: the thing you
/// most likely want on top, the permanent version under it, the refusal below, and the escape
/// hatch as a plain link. See docs/spec-v1.html section 6.
public struct ApprovalCardView: View {
    public let card: ApprovalCardData
    /// Answered cards keep their place in the thread but stop offering buttons.
    public let answered: Bool
    /// What was chosen, when known on this device; nil means answered elsewhere.
    public let chosen: ApprovalAnswerData.Answer?
    public let answer: (ApprovalAnswerData.Answer) -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        card: ApprovalCardData,
        answered: Bool = false,
        chosen: ApprovalAnswerData.Answer? = nil,
        answer: @escaping (ApprovalAnswerData.Answer) -> Void
    ) {
        self.card = card
        self.answered = answered
        self.chosen = chosen
        self.answer = answer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            subject
            if let amount = card.amount {
                Text(amount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .accessibilityLabel("Amount")
            }
            if answered {
                outcome
            } else {
                choices
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 12)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { appeared = true }
        }
        .sensoryFeedback(.warning, trigger: appeared) { _, shown in shown && !answered }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(verb.sentence)")
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.tint.opacity(0.14), in: Circle())
            Text(answered ? "Approval" : "Yorozu wants to")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// The action as a sentence, with the target as its object. A command or a path is shown
    /// as code, since that is what it is; an email address or a shop name is prose.
    private var subject: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verb.sentence)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !card.target.isEmpty {
                Text(card.target)
                    .font(verb.isCode ? .callout.monospaced() : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(verb.isCode ? 6 : 3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(verb.isCode ? 10 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        verb.isCode ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
        }
    }

    private var choices: some View {
        VStack(spacing: 8) {
            choice(.yes, "Allow", prominent: true)
            choice(.always, "Allow and don't ask again", prominent: false)
            choice(.no, "Don't allow", prominent: false)
            Button("Discuss first") { answer(.discuss) }
                .font(.subheadline)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .frame(minHeight: 44)
                .accessibilityHint("Ask Yorozu to explain before deciding")
            Text(alwaysNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    private func choice(_ value: ApprovalAnswerData.Answer, _ title: String, prominent: Bool) -> some View {
        Button {
            answer(value)
        } label: {
            Text(title)
                .font(.body.weight(prominent ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? Color.accentColor : quietButtonTint)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .buttonBorderShape(.roundedRectangle(radius: 10))
    }

    private var outcome: some View {
        HStack(spacing: 8) {
            Image(systemName: chosen == .no ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(chosen == .no ? Color.secondary : Color.accentColor)
            Text(outcomeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 32)
    }

    private var outcomeText: String {
        switch chosen {
        case .yes: "Allowed"
        case .always: "Allowed, and won't ask again"
        case .no: "Not allowed"
        case .discuss: "Discussing"
        case nil: "Answered on another device"
        }
    }

    /// What the always button promises. Tapping it names no target, so the rule it writes is
    /// class-level — saying anything narrower here would be a promise the card cannot keep.
    private var alwaysNote: String {
        "“Allow and don't ask again” covers every \(verb.noun) from now on."
    }

    private var cardBackground: Color {
        #if os(iOS)
            Color(.secondarySystemGroupedBackground)
        #else
            Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private var quietButtonTint: Color {
        #if os(iOS)
            Color(.tertiarySystemFill)
        #else
            Color(nsColor: .quaternaryLabelColor)
        #endif
    }

    // MARK: Wording

    private struct Verb {
        let sentence: String
        let noun: String
        let isCode: Bool
    }

    /// The wire class is kebab-case; the card speaks. Unknown classes fall back to the words
    /// in the class name, so a new tool never shows an empty card.
    private var verb: Verb {
        switch card.actionClass {
        case "send-message": return Verb(sentence: "Send a message", noun: "message", isCode: false)
        case "purchase": return Verb(sentence: "Make a purchase", noun: "purchase", isCode: false)
        case "transfer-money": return Verb(sentence: "Transfer money", noun: "transfer", isCode: false)
        case "book": return Verb(sentence: "Make a booking", noun: "booking", isCode: false)
        case "run-command": return Verb(sentence: "Run a command", noun: "command", isCode: true)
        case "edit-file": return Verb(sentence: "Change a file", noun: "file change", isCode: true)
        case "delete-file": return Verb(sentence: "Delete a file", noun: "file deletion", isCode: true)
        default:
            let words = card.actionClass.replacingOccurrences(of: "-", with: " ")
            return Verb(sentence: words.prefix(1).uppercased() + words.dropFirst(), noun: words, isCode: false)
        }
    }
}
