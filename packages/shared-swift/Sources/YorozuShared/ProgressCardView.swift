import SwiftUI

/// A numbered activity ledger for long-running work. It keeps every state explicit in text and
/// shape, so vermilion and sage add hierarchy without becoming the only status signal.
public struct ProgressCardView: View {
    public let card: ProgressCardData

    public init(card: ProgressCardData) {
        self.card = card
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
            header
            if let fraction = card.fraction { progress(fraction) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.steps.indices), id: \.self) { index in
                    step(card.steps[index], number: index + 1, isLast: index == card.steps.indices.last)
                }
            }
        }
        .yorozuPaperCard()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.title)
        .accessibilityValue(spoken)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: LayoutMetrics.inner) {
            YorozuMark(dimension: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("ACTIVITY")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.9)
                    .foregroundStyle(YorozuPalette.vermilion)
                Text(card.title)
                    .font(.headline)
                    .foregroundStyle(YorozuPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LayoutMetrics.inner)
            if card.running {
                ProgressView().controlSize(.small).tint(YorozuPalette.vermilion)
            } else {
                Label(failed ? String(localized: "Failed") : String(localized: "Done"),
                      systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(YorozuPalette.sage))
            }
        }
    }

    private func progress(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            HStack {
                Text("Progress").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(YorozuPalette.ink)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(failed ? .red : YorozuPalette.vermilion)
                .animation(.snappy, value: fraction)
        }
    }

    private func step(_ step: ProgressStep, number: Int, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: LayoutMetrics.stack) {
            VStack(spacing: 0) {
                numberMark(number, state: step.state)
                if !isLast {
                    Rectangle()
                        .fill(YorozuPalette.rule)
                        .frame(width: 1, height: 16)
                        .accessibilityHidden(true)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.inner) {
                Text(step.label)
                    .font(.subheadline)
                    .foregroundStyle(step.state == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(YorozuPalette.ink))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(stateLabel(step.state))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stateColour(step.state))
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(step.label), \(stateLabel(step.state))")
    }

    private func numberMark(_ number: Int, state: ProgressStep.State) -> some View {
        Text(number.formatted(.number.precision(.integerLength(2))))
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(markForeground(state))
            .frame(width: 26, height: 26)
            .background(markBackground(state), in: Circle())
            .overlay(Circle().strokeBorder(markBorder(state), lineWidth: 1))
    }

    private func stateLabel(_ state: ProgressStep.State) -> String {
        switch state {
        case .pending: String(localized: "Waiting")
        case .running: String(localized: "Current")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        }
    }

    private func stateColour(_ state: ProgressStep.State) -> AnyShapeStyle {
        switch state {
        case .pending: AnyShapeStyle(.secondary)
        case .running: AnyShapeStyle(YorozuPalette.vermilion)
        case .done: AnyShapeStyle(YorozuPalette.sage)
        case .failed: AnyShapeStyle(.red)
        }
    }

    private func markForeground(_ state: ProgressStep.State) -> AnyShapeStyle {
        switch state {
        case .running, .done, .failed: AnyShapeStyle(Color.white)
        case .pending: AnyShapeStyle(.secondary)
        }
    }

    private func markBackground(_ state: ProgressStep.State) -> AnyShapeStyle {
        switch state {
        case .pending: AnyShapeStyle(Color.clear)
        case .running: AnyShapeStyle(YorozuPalette.vermilion)
        case .done: AnyShapeStyle(YorozuPalette.sage)
        case .failed: AnyShapeStyle(Color.red)
        }
    }

    private func markBorder(_ state: ProgressStep.State) -> Color {
        state == .pending ? YorozuPalette.rule : .clear
    }

    private var failed: Bool { card.steps.contains { $0.state == .failed } }

    private var spoken: String {
        let done = card.steps.filter { $0.state == .done }.count
        return card.running
            ? "\(done) of \(card.steps.count) steps done"
            : failed ? "failed" : "finished"
    }
}
