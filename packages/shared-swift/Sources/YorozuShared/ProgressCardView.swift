import SwiftUI

/// The progress card: a long job saying where it has got to. Nothing to answer and nothing to
/// tap — it is the one card that is only ever read, which is why it is the quietest of them.
/// Re-reported under the same id, so it moves in place rather than a new one appearing.
public struct ProgressCardView: View {
    public let card: ProgressCardData

    public init(card: ProgressCardData) {
        self.card = card
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            HStack(spacing: LayoutMetrics.inner) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if card.running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            bar
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                ForEach(card.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.inner) {
                        mark(for: step.state)
                        Text(step.label)
                            .font(.caption)
                            .foregroundStyle(step.state == .pending ? .tertiary : .secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(LayoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.title)
        .accessibilityValue(spoken)
    }

    private var failed: Bool { card.steps.contains { $0.state == .failed } }

    /// Thin, and only drawn when the card can say how far along it is: a bar that means
    /// nothing is worse than no bar.
    @ViewBuilder private var bar: some View {
        if let fraction = card.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(failed ? .red : .accentColor)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
                .animation(.snappy, value: fraction)
        }
    }

    /// The step's own state, at a glance: a spinner only for the one actually being worked on.
    @ViewBuilder private func mark(for state: ProgressStep.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").font(.caption2).foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
        }
    }

    /// What VoiceOver reads instead of a bar it cannot see: the steps settled out of the total.
    private var spoken: String {
        let done = card.steps.filter { $0.state == .done }.count
        return card.running
            ? "\(done) of \(card.steps.count) steps done"
            : failed ? "failed" : "finished"
    }
}
