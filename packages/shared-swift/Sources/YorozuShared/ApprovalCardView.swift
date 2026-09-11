import SwiftUI

/// The approval card: Yes / No / Never / Discuss, shared by the phone and the Mac chat.
/// `Never` is permanent, so it reads as the destructive choice. See docs/spec-v1.html section 6.
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
                HStack(spacing: 8) {
                    ForEach(ApprovalAnswerData.Answer.allCases, id: \.self) { choice in
                        Button(choice.rawValue.capitalized) { answer(choice) }
                            .buttonStyle(.bordered)
                            .tint(tint(for: choice))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func tint(for choice: ApprovalAnswerData.Answer) -> Color? {
        switch choice {
        case .yes: .accentColor
        case .never: .red
        case .no, .discuss: nil
        }
    }
}
