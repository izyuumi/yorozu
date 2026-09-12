import SwiftUI

/// The approval card: Yes / Yes-and-never-ask / No / Discuss, shared by the phone and the Mac
/// chat. The second button is a yes that also writes a permanent rule, so it reads as an accent
/// choice rather than a destructive one. See docs/spec-v1.html section 6.
public struct ApprovalCardView: View {
    public let card: ApprovalCardData
    /// Answered cards keep their place in the thread but stop offering buttons.
    public let answered: Bool
    public let answer: (ApprovalAnswerData.Answer) -> Void

    public init(
        card: ApprovalCardData,
        answered: Bool = false,
        answer: @escaping (ApprovalAnswerData.Answer) -> Void
    ) {
        self.card = card
        self.answered = answered
        self.answer = answer
    }

    /// The wire class is kebab-case: "send-message" reads as "Send message".
    private var title: String {
        let words = card.actionClass.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "hand.raised").font(.headline)
            Text(card.target)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let amount = card.amount {
                Text(amount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .font(.callout.bold())
            }
            if answered {
                Text("Answered").font(.caption).foregroundStyle(.secondary)
            } else {
                // Four labelled buttons rarely fit one line at larger Dynamic Type sizes, so
                // the row gives way to a full-width column rather than truncating them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(ApprovalAnswerData.Answer.allCases, id: \.self) { button(for: $0) }
                    }
                    VStack(spacing: 8) {
                        ForEach(ApprovalAnswerData.Answer.allCases, id: \.self) {
                            button(for: $0).frame(maxWidth: .infinity)
                        }
                    }
                }
                Text(alwaysNote).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// What the always button promises. Tapping it names no target, so the rule it writes is
    /// class-level — saying anything narrower here would be a promise the card cannot keep.
    private var alwaysNote: String {
        "\"Yes, and never ask again\" applies to all \(title.lowercased()) actions from now on"
    }

    private func button(for choice: ApprovalAnswerData.Answer) -> some View {
        Button(label(for: choice)) { answer(choice) }
            .buttonStyle(.bordered)
            .tint(tint(for: choice))
            .frame(minHeight: 44)
    }

    private func label(for choice: ApprovalAnswerData.Answer) -> String {
        switch choice {
        case .yes: "Yes"
        case .always: "Yes, and never ask again"
        case .no: "No"
        case .discuss: "Discuss"
        }
    }

    private func tint(for choice: ApprovalAnswerData.Answer) -> Color? {
        switch choice {
        case .yes, .always: .accentColor
        case .no, .discuss: nil
        }
    }
}
