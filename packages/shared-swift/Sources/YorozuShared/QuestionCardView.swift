import SwiftUI

/// The question card: what the agent needs decided, as buttons. Shaped like
/// ``ApprovalCardView`` because it sits in the same thread and is answered the same way — the
/// difference is what it means. An approval asks permission for something already decided;
/// this asks which thing to do, and the agent's tool call is waiting on the answer.
public struct QuestionCardView: View {
    public let card: QuestionCardData
    /// Answered cards keep their place in the thread but stop offering buttons.
    public let answered: Bool
    public let chosen: String?
    public let answer: (String) -> Void

    @State private var other = ""
    @FocusState private var writing: Bool

    public init(
        card: QuestionCardData,
        answered: Bool = false,
        chosen: String? = nil,
        answer: @escaping (String) -> Void
    ) {
        self.card = card
        self.answered = answered
        self.chosen = chosen
        self.answer = answer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            Label(card.question, systemImage: "questionmark.bubble")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if answered {
                Label(chosen.map { "Answered: \($0)" } ?? String(localized: "Answered"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // One per line: the options are sentences, not words, and a row of them
                // truncates the moment Dynamic Type grows.
                VStack(spacing: LayoutMetrics.inner) {
                    ForEach(card.options, id: \.self) { option in
                        Button { answer(option) } label: {
                            Text(option)
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: controlTarget, alignment: .leading)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(QuestionOptionStyle())
                    }
                }
                if card.offersFreeText { freeText }
            }
        }
        .yorozuPaperCard()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var freeText: some View {
        HStack(spacing: LayoutMetrics.inner) {
            TextField("Something else", text: $other, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($writing)
                .padding(.horizontal, LayoutMetrics.stack)
                .padding(.vertical, LayoutMetrics.inner)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous))
                .onSubmit(sendOther)
            Button(action: sendOther) {
                Image(systemName: "arrow.up.circle.fill")
                    .frame(minWidth: controlTarget, minHeight: controlTarget)
                    .contentShape(Rectangle())
            }
                .font(.title3)
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
                .accessibilityLabel("Send answer")
        }
    }

    private var trimmed: String { other.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendOther() {
        guard !trimmed.isEmpty else { return }
        writing = false
        answer(trimmed)
    }
}

/// AppKit's bordered button makes sentence-length labels single-line even when the Text can
/// wrap. Keep the full option as the button label and draw its pressed state around that label.
private struct QuestionOptionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, LayoutMetrics.inner)
            .padding(.vertical, LayoutMetrics.tight)
            .foregroundStyle(.primary)
            .background(
                configuration.isPressed ? YorozuPalette.stone : YorozuPalette.canvas,
                in: RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous)
                    .strokeBorder(YorozuPalette.rule, lineWidth: 0.8)
            }
            .contentShape(Rectangle())
    }
}
