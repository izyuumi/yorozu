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
            HStack(alignment: .firstTextBaseline) {
                Text("Model and effort")
                    .font(.headline)
                    .foregroundStyle(YorozuPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Done", action: dismiss)
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, LayoutMetrics.gutter)
            .padding(.top, LayoutMetrics.tight)
            // Short catalogs hug their rows; a long one scrolls inside the same frame.
            ViewThatFits(in: .vertical) {
                choices
                ScrollView { choices }.scrollBounceBehavior(.basedOnSize)
            }
        }
        .background(YorozuPalette.canvas, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(YorozuPalette.rule.opacity(0.82), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        // An overlay sits outside the chat's tinted subtree, so Done takes the app colour here.
        .yorozuTint()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            YorozuQuestion("Which model?")
            YorozuChoiceCard([Choice(String(localized: "Auto"), selected: model == nil) { model = nil }])
            ForEach(ModelOption.groupedByProvider(models), id: \.label) { group in
                YorozuCaption(group.label).padding(.top, LayoutMetrics.tight)
                YorozuChoiceCard(group.options.map { option in
                    // The provider is the caption above, so the row says the model alone; the
                    // accessibility label keeps both, as the flattened native menu did.
                    Choice(option.label, accessibilityLabel: option.menuLabel,
                           selected: model == option.id) { model = option.id }
                })
            }
            YorozuQuestion("How much effort?")
                .padding(.top, LayoutMetrics.inner)
            YorozuPillPicker(
                [Choice(String(localized: "Default"), selected: effort == nil) { effort = nil }]
                    + efforts.map { level in Choice(level.label, selected: effort == level) { effort = level } }
            )
        }
        .padding(.horizontal, LayoutMetrics.gutter)
        .padding(.bottom, LayoutMetrics.gutter)
    }
}

/// One option in a ``YorozuChoiceCard`` or ``YorozuPillPicker``: what it says, whether it is the
/// current pick, and what choosing it does.
struct Choice: Identifiable {
    let label: String
    let accessibilityLabel: String
    let selected: Bool
    let pick: () -> Void
    var id: String { label }

    init(_ label: String, accessibilityLabel: String? = nil,
         selected: Bool, pick: @escaping () -> Void) {
        self.label = label
        self.accessibilityLabel = accessibilityLabel ?? label
        self.selected = selected
        self.pick = pick
    }
}

/// A small caption over a group of rows: the provider over its models.
struct YorozuCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(YorozuPalette.ink.opacity(0.62))
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
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
                    Rectangle().fill(YorozuPalette.rule.opacity(0.72)).frame(height: 0.5)
                        .padding(.leading, 14)
                }
                Button(action: choice.pick) {
                    HStack(spacing: 8) {
                        Text(choice.label)
                            .foregroundStyle(YorozuPalette.ink)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(YorozuPalette.vermilion)
                            .opacity(choice.selected ? 1 : 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.accessibilityLabel)
                .accessibilityAddTraits(choice.selected ? .isSelected : [])
            }
        }
        .yorozuPaperCard(padding: 0, radius: 12)
    }
}

/// A row of capsules for a short, ordered scale such as effort: the pick is filled in
/// vermilion, the rest are paper. Scrolls sideways when a catalog offers more than fits.
struct YorozuPillPicker: View {
    let choices: [Choice]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ choices: [Choice]) { self.choices = choices }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            pills
            ScrollView(.horizontal, showsIndicators: false) { pills.padding(.vertical, 2) }
                .scrollClipDisabled()
        }
    }

    private var pills: some View {
        HStack(spacing: 6) {
            ForEach(choices) { choice in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2), choice.pick)
                } label: {
                    Text(choice.label)
                        .font(.subheadline.weight(choice.selected ? .semibold : .regular))
                        // Paper on vermilion, not white: white on the dark-mode vermilion is under 4.5:1.
                        .foregroundStyle(choice.selected ? YorozuPalette.paper : YorozuPalette.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(choice.selected ? YorozuPalette.vermilion : YorozuPalette.paper, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(YorozuPalette.rule.opacity(choice.selected ? 0 : 0.72),
                                                   lineWidth: 0.75)
                        }
                        // 44 pt tall to the finger, 36 pt to the eye.
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.accessibilityLabel)
                .accessibilityAddTraits(choice.selected ? .isSelected : [])
            }
        }
    }
}
