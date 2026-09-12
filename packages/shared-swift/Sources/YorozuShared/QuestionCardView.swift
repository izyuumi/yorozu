import SwiftUI

/// The question card: what the agent needs decided, as buttons. Shaped like
/// ``ApprovalCardView`` because it sits in the same thread and is answered the same way — the
/// difference is what it means. An approval asks permission for something already decided;
/// this asks which thing to do, and the agent's tool call is waiting on the answer.
public struct QuestionCardView: View {
    public let card: QuestionCardData
    /// Answered cards keep their place in the thread but stop offering buttons.
    public let answered: Bool
    public let answer: (String) -> Void

    @State private var other = ""
    @FocusState private var writing: Bool

    public init(card: QuestionCardData, answered: Bool = false, answer: @escaping (String) -> Void) {
        self.card = card
        self.answered = answered
        self.answer = answer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(card.question, systemImage: "questionmark.bubble")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if answered {
                Text("Answered").font(.caption).foregroundStyle(.secondary)
            } else {
                // One per line: the options are sentences, not words, and a row of them
                // truncates the moment Dynamic Type grows.
                VStack(spacing: 8) {
                    ForEach(card.options, id: \.self) { option in
                        Button { answer(option) } label: {
                            Text(option)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                }
                if card.offersFreeText { freeText }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var freeText: some View {
        HStack(spacing: 8) {
            TextField("Something else", text: $other, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($writing)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary, in: Capsule())
                .onSubmit(sendOther)
            Button("Send", systemImage: "arrow.up.circle.fill", action: sendOther)
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
        }
    }

    private var trimmed: String { other.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendOther() {
        guard !trimmed.isEmpty else { return }
        writing = false
        answer(trimmed)
    }
}
