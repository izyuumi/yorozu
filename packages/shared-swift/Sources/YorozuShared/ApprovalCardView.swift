import SwiftUI

/// The approval card: the agent asking permission for one external action. It reads like a
/// system permission prompt rather than a chat bubble, because that is what it is — a request
/// to act on your behalf — and the answers stack the way a permission prompt's do: the thing you
/// most likely want on top, the wider grants under it, the refusal below, and the escape hatch
/// as a plain link.
///
/// What it shows is the concrete payload, not the tool that would commit it: who it lands on,
/// which account it comes out of, how much, what it says, and the one line the tool declares
/// about what happens afterwards. A decision can only be as good as what was in front of it.
/// See docs/spec-v1.html section 6 and docs/spec-v1.5.md.
public struct ApprovalCardView: View {
    public let card: ApprovalCardData
    /// Answered cards keep their place in the thread but stop offering buttons.
    public let answered: Bool
    public let pending: Bool
    public let disposition: ApprovalStatusData.Status?
    /// What was chosen, when known on this device; nil means answered elsewhere.
    public let chosen: ApprovalAnswerData.Answer?
    public let answer: (ApprovalAnswerData.Answer, ApprovalRule?) -> Void

    @State private var appeared = false
    @State private var editingRule: ApprovalRule?
    @State private var itemsExpanded = ChatShowcase.expanded
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        card: ApprovalCardData,
        answered: Bool = false,
        pending: Bool = false,
        disposition: ApprovalStatusData.Status? = nil,
        chosen: ApprovalAnswerData.Answer? = nil,
        answer: @escaping (ApprovalAnswerData.Answer, ApprovalRule?) -> Void
    ) {
        self.card = card
        self.answered = answered
        self.pending = pending
        self.disposition = disposition
        self.chosen = chosen
        self.answer = answer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
            header
            subject
            if let amount = card.amount {
                let formattedAmount = ApprovalAmountFormatter.string(amount: amount, currency: card.currency)
                Text(formattedAmount)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    // The label must carry the number: a bare "Amount" replaced it.
                    .accessibilityLabel(
                        "Amount: \(formattedAmount)"
                    )
            }
            scopeRows
            content
            items
            consequence
            if card.mustConfirm == true { confirmNote }
            if pending {
                Text("Answer pending · waiting for host")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if disposition == .noLongerNeeded || disposition == .expired {
                Text("No longer needed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if answered {
                outcome
            } else {
                if disposition == .rejected {
                    Text("Answer not applied")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if card.nativeAgent != nil {
                    HStack {
                        choice(.yes, "Allow", prominent: true)
                        choice(.no, "Don't allow", prominent: false)
                    }
                } else {
                    choices
                }
            }
        }
        .padding(LayoutMetrics.cardPadding)
        // Capped where a bubble is capped, and for the same reason: stretched across a wide
        // Mac window the buttons end up the width of the screen and the card stops reading as
        // a prompt. On a phone the cap is wider than the screen and changes nothing.
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
                .strokeBorder(YorozuPalette.rule.opacity(0.85), lineWidth: 0.8)
        )
        .onAppear {
            appeared = true
            // Screenshot only, and inert otherwise — see ``ChatShowcase``.
            if ChatShowcase.ruleEditor, !answered { editingRule = card.suggestedRule }
        }
        .sensoryFeedback(.warning, trigger: appeared) { _, shown in shown && !answered }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(verb.sentence)")
        // The rule the "Always allow" button is really about. Nothing is saved until Save.
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule, title: "Always allow") { edited in
                editingRule = nil
                answer(.always, edited)
            } onCancel: {
                editingRule = nil
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: LayoutMetrics.inner) {
            Image(systemName: "hand.raised.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(YorozuPalette.vermilion)
                .frame(width: 28, height: 28)
                .background(YorozuPalette.vermilion.opacity(0.12), in: Circle())
            Text(answered ? String(localized: "Approval") : (card.nativeAgent?.label ?? String(localized: "Yorozu wants to")))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// The action as a sentence, with the target as its object. A command or a path is shown
    /// as code, since that is what it is; an email address or a shop name is prose.
    private var subject: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            Text(verb.sentence)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !card.target.isEmpty {
                ApprovalDetailText(
                    text: card.target,
                    font: verb.isCode ? .callout.monospaced() : .callout,
                    previewLines: verb.isCode ? 6 : 3,
                    expandLabel: "Show full action",
                    collapseLabel: "Show less action",
                    identifier: "approvalActionDisclosure"
                )
                    .padding(verb.isCode ? LayoutMetrics.inner : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        verb.isCode ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous)
                    )
            }
        }
    }

    /// Recipient, merchant, account, category, quantity — whichever the tool could fill in.
    @ViewBuilder private var scopeRows: some View {
        let rows = card.scope?.rows ?? []
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.inner) {
                        Text(row.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)
                        Text(row.value)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// What would actually be sent, as far as the card carries it.
    @ViewBuilder private var content: some View {
        if let summary = card.scope?.contentSummary, !summary.isEmpty {
            ApprovalDetailText(
                text: summary,
                font: .callout,
                previewLines: 5,
                expandLabel: "Show full content",
                collapseLabel: "Show less content",
                identifier: "approvalContentDisclosure"
            )
                .padding(LayoutMetrics.inner)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous))
        }
    }

    /// The exact list one decision covers. Collapsed past a handful, because the point is that
    /// the list is *exact* rather than that it fills the screen — but every item is reachable.
    @ViewBuilder private var items: some View {
        if let items = card.items, !items.isEmpty {
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        itemsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: itemsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                        Text("^[\(items.count) item](inflect: true) in this batch")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: controlTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("approvalItemsDisclosure")
                .accessibilityValue(itemsExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("This decision covers exactly these items")

                ForEach(itemsExpanded ? items : Array(items.prefix(Self.itemsShown))) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                            Text(item.label).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = item.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(itemsExpanded ? nil : 1)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !itemsExpanded, items.count > Self.itemsShown {
                    Text("and \(items.count - Self.itemsShown) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(LayoutMetrics.inner)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous))
        }
    }

    /// How many items are shown before the list collapses.
    private static let itemsShown = 4

    /// The one line the tool declares about what happens once this runs.
    @ViewBuilder private var consequence: some View {
        if let line = card.scope?.consequence, !line.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.caption)
                Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Set on the actions no rule may ever stand in for, so the card says why it is here.
    private var confirmNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.shield.fill").font(.caption)
            Text("Yorozu always asks about this kind of action, whatever rules are saved.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
    }

    private var choices: some View {
        VStack(spacing: LayoutMetrics.inner) {
            #if os(macOS)
                choice(.yes, "Allow once", prominent: true)
                HStack(spacing: LayoutMetrics.inner) {
                    choice(.task, "Allow for this task", prominent: false)
                    choice(.no, "Don't allow", prominent: false)
                }
            #else
                HStack(spacing: LayoutMetrics.inner) {
                    choice(.yes, "Allow once", prominent: true)
                    choice(.task, "For this task", prominent: false)
                }
            #endif
            // A grant that ends with the turn, so it is offered wherever a card is — but it
            // has nothing to promise about the actions no rule may stand in for either.
            if card.mustConfirm != true, let suggestion = card.suggestedRule {
                Button {
                    editingRule = suggestion
                } label: {
                    Text(alwaysTitle)
                        .frame(maxWidth: .infinity, minHeight: controlTarget)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: LayoutMetrics.controlRadius))
                .accessibilityHint("Opens a rule you can widen before saving")
            }
            #if !os(macOS)
                HStack(spacing: LayoutMetrics.inner) {
                    choice(.no, "Don't allow", prominent: false)
                    Button { answer(.discuss, nil) } label: {
                        Text("Discuss first")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: controlTarget)
                    }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: LayoutMetrics.controlRadius))
                        .accessibilityHint("Ask Yorozu to explain before deciding")
                }
            #endif
            #if os(macOS)
                Button("Discuss first") { answer(.discuss, nil) }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(minHeight: controlTarget)
                    .accessibilityHint("Ask Yorozu to explain before deciding")
            #endif
            Text(grantNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    @ViewBuilder private func choice(_ value: ApprovalAnswerData.Answer, _ title: String, prominent: Bool) -> some View {
        let button = Button { answer(value, nil) } label: {
            Text(title)
                .font(.body.weight(prominent ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: controlTarget)
        }
        if prominent { button.buttonStyle(.borderedProminent) }
        else { button.buttonStyle(.bordered) }
    }

    private var outcome: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            HStack(spacing: LayoutMetrics.inner) {
                Image(systemName: chosen == .no ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(chosen == .no ? Color.secondary : Color.accentColor)
                Text(outcomeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if chosen == .always, let rule = card.suggestedRule {
                HStack(spacing: LayoutMetrics.inner) {
                    Text("Rule saved: \(rule.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Edit") { editingRule = rule }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .frame(minWidth: controlTarget, minHeight: controlTarget)
                        .contentShape(.rect)
                }
                .padding(LayoutMetrics.inner)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous))
            }
        }
        .frame(minHeight: 32, alignment: .leading)
    }

    private var outcomeText: String {
        switch chosen {
        case .yes: String(localized: "Allowed once")
        case .task: String(localized: "Allowed for this task")
        case .always: String(localized: "Allowed, and saved as a rule")
        case .no: String(localized: "Not allowed")
        case .discuss: String(localized: "Discussing")
        case nil: String(localized: "Answered on another device")
        }
    }

    /// The always button names the scope it would actually cover, because a button that says
    /// "don't ask again" and then means something narrower is a promise the card cannot keep.
    private var alwaysTitle: String {
        guard let narrowed = card.suggestedRule?.summary else { return String(localized: "Always allow…") }
        return String(localized: "Always allow \(narrowed)…")
    }

    /// What the grants under the first one actually promise. It only mentions rules when one
    /// is on offer: a batch is not offered one, and neither is anything that must be confirmed.
    private var grantNote: String {
        if card.mustConfirm == true { return String(localized: "This one cannot be turned into a rule.") }
        if card.suggestedRule == nil {
            return String(localized: "“Allow for this task” lasts until this task is done. This decision covers exactly the items listed above.")
        }
        return String(localized: "“Allow for this task” lasts until this task is done. A rule lasts until you revoke it.")
    }

    private var cardBackground: Color { YorozuPalette.paper }

    // MARK: Wording

    struct Verb {
        let sentence: String
        let noun: String
        let isCode: Bool
    }

    /// The wire class is kebab-case; the card speaks. Unknown classes fall back to the words
    /// in the class name, so a new tool never shows an empty card.
    private var verb: Verb {
        Self.verb(for: card.actionClass)
    }

    nonisolated static func verb(for actionClass: String) -> Verb {
        switch actionClass {
        case "send-message": return Verb(sentence: String(localized: "Send a message"), noun: String(localized: "message"), isCode: false)
        case "purchase": return Verb(sentence: String(localized: "Make a purchase"), noun: String(localized: "purchase"), isCode: false)
        case "transfer-money": return Verb(sentence: String(localized: "Transfer money"), noun: String(localized: "transfer"), isCode: false)
        case "book": return Verb(sentence: String(localized: "Make a booking"), noun: String(localized: "booking"), isCode: false)
        case "run-command": return Verb(sentence: String(localized: "Run a command"), noun: String(localized: "command"), isCode: true)
        case "edit-file": return Verb(sentence: String(localized: "Change a file"), noun: String(localized: "file change"), isCode: true)
        case "delete-file": return Verb(sentence: String(localized: "Delete a file"), noun: String(localized: "file deletion"), isCode: true)
        default:
            let words = actionClass.replacingOccurrences(of: "-", with: " ")
            return Verb(sentence: words.prefix(1).uppercased() + words.dropFirst(), noun: words, isCode: false)
        }
    }
}

/// Keeps compact previews while making every supplied character reachable before approval.
/// Measure the same font at the available width, so disclosure follows actual wrapping rather
/// than a character-count guess that breaks with Dynamic Type or narrow windows.
private struct ApprovalDetailText: View {
    let text: String
    let font: Font
    let previewLines: Int
    let expandLabel: LocalizedStringKey
    let collapseLabel: LocalizedStringKey
    let identifier: String

    @State private var expanded = ChatShowcase.expanded
    @State private var previewHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            Text(text)
                .lineLimit(expanded ? nil : previewLines)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        .hidden()
                        .accessibilityHidden(true)
                }
                .font(font)
                .foregroundStyle(.secondary)

            if expanded || fullHeight > previewHeight + 0.5 {
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Show less" : expandLabel)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: controlTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(expanded ? collapseLabel : expandLabel)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
    }
}

extension ApprovalRule {
    /// The rule as one phrase, for a button and a settings row: "message to bob@example.com",
    /// "purchase at Kurasu up to $48". Pure, so a test can check it without drawing anything.
    public var summary: String {
        let noun = ApprovalCardView.verb(for: actionClass).noun
        var phrase = noun
        if let recipient = scope?["recipient"] { phrase += " to \(recipient.phrase)" }
        if let merchant = scope?["merchant"] { phrase += " at \(merchant.phrase)" }
        if let account = scope?["account"] { phrase += " from \(account.phrase)" }
        if let category = scope?["category"] { phrase += " in \(category.phrase)" }
        if let target = scope?["target"] { phrase += " on \(target.phrase)" }
        if let cap = maxAmount {
            let amount = ApprovalAmountFormatter.string(amount: cap, currency: currency)
            phrase += " up to \(amount)"
        } else if let currency, !currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phrase += " in \(currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
        }
        return phrase
    }
}

extension ApprovalRuleField {
    /// One pattern in words. A glob and a prefix are shown as what they are, because the
    /// difference between "anything at this domain" and "this address" is the whole point.
    public var phrase: String {
        switch mode {
        case .exact: value
        case .prefix: "\(value)…"
        case .glob: value
        }
    }
}
