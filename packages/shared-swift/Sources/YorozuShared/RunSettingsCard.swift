import SwiftUI

/// The composer's model and effort choices, drawn in place over the chat rather than as a
/// system sheet: a UIKit sheet takes the keyboard with it, and the draft being typed is what
/// these settings are for. Everything here is a SwiftUI button, so first responder never moves.
///
/// Both choices stay open together — picking a model changes which efforts it offers, and the
/// second choice is usually made right after the first. `Done` or the scrim closes it.
struct RunSettingsCard: View {
    let models: [ModelOption]
    let efforts: [ReasoningEffort]
    @Binding var model: String?
    @Binding var effort: ReasoningEffort?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Model and effort")
                    .font(.headline)
                    .foregroundStyle(YorozuPalette.ink)
                Spacer(minLength: 8)
                Button("Done", action: dismiss)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, LayoutMetrics.gutter)
            .padding(.vertical, LayoutMetrics.stack)
            // Short catalogs hug their rows; a long one scrolls inside the same frame.
            ViewThatFits(in: .vertical) {
                choices
                ScrollView { choices }
            }
        }
        .background(YorozuPalette.canvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(YorozuPalette.rule.opacity(0.82), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        // An overlay sits outside the chat's tinted subtree, so Done takes the app colour here.
        .yorozuTint()
        .accessibilityAddTraits(.isModal)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
            YorozuQuestion("Which model?")
            YorozuChoiceCard([Choice("Auto", selected: model == nil) { model = nil }])
            ForEach(ModelOption.groupedByProvider(models), id: \.label) { group in
                Text(group.label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 4)
                YorozuChoiceCard(group.options.map { option in
                    Choice(option.label, selected: model == option.id) { model = option.id }
                })
            }
            YorozuQuestion("How much effort?")
                .padding(.top, LayoutMetrics.inner)
            YorozuChoiceCard(
                [Choice("Default", selected: effort == nil) { effort = nil }]
                    + efforts.map { level in Choice(level.label, selected: effort == level) { effort = level } }
            )
        }
        .padding(.horizontal, LayoutMetrics.gutter)
        .padding(.bottom, LayoutMetrics.gutter)
    }
}

/// One row of a ``YorozuChoiceCard``: what it says, whether it is the current pick, and what
/// choosing it does.
struct Choice: Identifiable {
    let label: String
    let selected: Bool
    let pick: () -> Void
    var id: String { label }

    init(_ label: String, selected: Bool, pick: @escaping () -> Void) {
        self.label = label
        self.selected = selected
        self.pick = pick
    }
}

/// A paper card of single-choice rows with a vermilion check on the current one: the app's own
/// grouped list, for places a `List` cannot size itself.
struct YorozuChoiceCard: View {
    let choices: [Choice]

    init(_ choices: [Choice]) { self.choices = choices }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 {
                    Divider().overlay(YorozuPalette.rule.opacity(0.72)).padding(.leading, 14)
                }
                Button(action: choice.pick) {
                    HStack {
                        Text(choice.label)
                            .foregroundStyle(YorozuPalette.ink)
                        Spacer(minLength: 8)
                        if choice.selected {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(YorozuPalette.vermilion)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice.selected ? .isSelected : [])
            }
        }
        .yorozuPaperCard(padding: 0, radius: 12)
    }
}
