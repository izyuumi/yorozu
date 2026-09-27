import SwiftUI

/// The skills a draft is asking to choose from: all of them after a lone slash, otherwise those
/// whose name holds what follows it, names that start with it first. None for any other
/// draft — a slash in the middle of a sentence, or a command that already has its space — so
/// the space a pick inserts is also what closes the picker.
func skillMatches(for draft: String, in skills: [SkillOption]) -> [SkillOption] {
    guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
    let query = draft.dropFirst().lowercased()
    guard !query.isEmpty else { return skills }
    let found = skills.filter { $0.name.lowercased().contains(query) }
    return found.filter { $0.name.lowercased().hasPrefix(query) }
        + found.filter { !$0.name.lowercased().hasPrefix(query) }
}

/// The skills a draft's slash matched, floating over the foot of the transcript. Drawn in
/// place rather than as a menu or popover for the reason ``RunSettingsCard`` is: those take
/// first responder, and the draft being typed is what the pick goes into. Never drawn empty;
/// the caller leaves it out of the tree when nothing matches.
struct SkillPicker: View {
    let skills: [SkillOption]
    /// The row the Mac's keys are on. Nil on the phone, which picks by tap alone.
    var highlighted: SkillOption.ID?
    var onHover: (SkillOption) -> Void = { _ in }
    let onPick: (SkillOption) -> Void
    let dismiss: () -> Void

    /// How much of the transcript's height the picker may cover before it scrolls inside.
    /// Rows at an accessibility size are several times taller, so they are given more of it.
    static func transcriptShare(_ size: DynamicTypeSize) -> CGFloat { size.isAccessibilitySize ? 0.85 : 0.62 }

    #if os(macOS)
        private static let inset: CGFloat = 4
    #else
        private static let inset: CGFloat = 0
        private static let rowPadding: CGFloat = 14
    #endif

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        // A few matches hug their rows; a long list scrolls inside the height it was given.
        ViewThatFits(in: .vertical) {
            rows
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: highlighted, initial: true) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
            }
        }
        .background(YorozuPalette.paper)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(YorozuPalette.rule.opacity(0.82), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skills")
        .accessibilityAction(.escape, dismiss)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                #if os(iOS)
                    if index > 0 {
                        Rectangle().fill(YorozuPalette.rule.opacity(0.72)).frame(height: 0.5)
                            .padding(.leading, Self.rowPadding)
                    }
                #endif
                Button { onPick(skill) } label: { row(skill) }
                    .buttonStyle(.plain)
                    .id(skill.id)
                    .accessibilityLabel(skill.name)
                    .accessibilityValue(
                        [skill.description, skill.argumentHint ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
                    .accessibilityAddTraits(skill.id == highlighted ? .isSelected : [])
                    #if os(macOS)
                        .onHover { inside in if inside { onHover(skill) } }
                    #endif
            }
        }
        .padding(Self.inset)
    }

    private func name(_ skill: SkillOption) -> some View {
        Text("/\(skill.name)")
            .fontWeight(.semibold)
            .foregroundStyle(YorozuPalette.ink)
    }

    @ViewBuilder private func hint(_ skill: SkillOption) -> some View {
        if let hint = skill.argumentHint, !hint.isEmpty {
            Text(hint)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    #if os(macOS)
        /// One line, as a Mac menu row is: the description gives way first.
        private func row(_ skill: SkillOption) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.inner) {
                name(skill).lineLimit(1).layoutPriority(2)
                hint(skill).lineLimit(1).layoutPriority(1)
                Text(skill.description)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, LayoutMetrics.inner)
            .frame(minHeight: controlTarget)
            .background(
                skill.id == highlighted ? YorozuPalette.stone.opacity(0.6) : .clear,
                in: RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
    #else
        private func row(_ skill: SkillOption) -> some View {
            VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                // The hint sits beside the name while both fit on a line, and under it when
                // the type size or the name's length says they do not.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.inner) {
                        name(skill)
                        hint(skill)
                    }
                    VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                        name(skill)
                        hint(skill)
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.rowPadding)
            .padding(.vertical, 10)
            .frame(minHeight: controlTarget)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
        }
    #endif
}
