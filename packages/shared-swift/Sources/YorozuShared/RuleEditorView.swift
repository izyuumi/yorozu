import SwiftUI

/// The rule editor: a small sheet, opened prefilled with the narrowest rule that would cover
/// the action in front of the user, and the one place a rule is ever written.
///
/// It opens narrow and widens only where the user says so — every field starts at the exact
/// value the action had, and setting one to "Any" is a decision they take rather than one taken
/// for them. That asymmetry is deliberate: an inferred scope must never become authority by
/// itself, so the sheet cannot save anything the user has not looked at. See story 19 and 23.
public struct RuleEditorView: View {
    /// What the sheet says it is doing: "Always allow" from a card, "Edit rule" from Settings.
    public let title: String
    public let onSave: (ApprovalRule) -> Void
    public let onCancel: () -> Void

    @State private var draft: Draft

    public init(
        rule: ApprovalRule,
        title: String,
        onSave: @escaping (ApprovalRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: Draft(rule: rule))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Action", value: ApprovalCardView.actionLabel(draft.actionClass))
                    Picker("Decision", selection: $draft.decision) {
                        Text("Allow").tag(ApprovalRule.Decision.always)
                        Text("Never allow").tag(ApprovalRule.Decision.never)
                    }
                } footer: {
                    Text(
                        draft.decision == .never
                            ? "A never rule wins over any allow rule it overlaps with."
                            : "Yorozu will do this without asking, until you revoke the rule."
                    )
                }

                Section {
                    ForEach($draft.fields) { $field in
                        FieldRow(field: $field)
                    }
                } header: {
                    Text("Scope")
                } footer: {
                    Text("Set a field to Any to widen the rule. A field left at Any is not checked at all.")
                }

                Section {
                    Toggle("Cap the amount", isOn: $draft.hasCap.animation())
                    if draft.hasCap {
                        TextField(
                            "Up to",
                            value: $draft.maxAmount,
                            format: .currency(code: Locale.current.currency?.identifier ?? "USD")
                        )
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                    }
                } footer: {
                    Text("Anything over the cap is asked about as usual.")
                }

                Section {
                    LabeledContent("This rule covers", value: draft.rule.summary)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft.rule) }
                        // A rule with every field widened to Any and no cap is exactly the
                        // blanket authorization the spec does not support, so it cannot be saved.
                        .disabled(!draft.isNarrowEnough)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    /// One editable scope field.
    struct FieldRow: View {
        @Binding var field: Draft.Field

        var body: some View {
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                HStack {
                    Text(field.label)
                    Spacer(minLength: 8)
                    Toggle("Any", isOn: $field.isAny.animation())
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Any \(field.label.lowercased())")
                    Text("Any").font(.caption).foregroundStyle(.secondary)
                }
                if !field.isAny {
                    HStack(spacing: LayoutMetrics.inner) {
                        Picker("Match", selection: $field.mode) {
                            Text("is").tag(ApprovalRuleField.Mode.exact)
                            Text("starts with").tag(ApprovalRuleField.Mode.prefix)
                            Text("matches").tag(ApprovalRuleField.Mode.glob)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        TextField(field.label, text: $field.value)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            #endif
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// The rule being edited, in a shape a Form can bind to. Pure: everything the sheet knows
    /// about turning one back into a rule lives here, so a test can check it without a view.
    public struct Draft: Equatable {
        public struct Field: Identifiable, Equatable {
            public let id: String
            public var mode: ApprovalRuleField.Mode
            public var value: String
            public var isAny: Bool

            var label: String {
                switch id {
                case "target": String(localized: "Target")
                case "operation": String(localized: "Operation")
                case "recipient": String(localized: "Recipient")
                case "account": String(localized: "Account")
                case "merchant": String(localized: "Merchant")
                case "category": String(localized: "Category")
                default: id.capitalized
                }
            }
        }

        let ruleId: String
        let actionClass: String
        let createdAt: Double?
        let lastUsed: Double?
        let useCount: Int?
        let enabled: Bool?
        public var decision: ApprovalRule.Decision
        public var fields: [Field]
        public var hasCap: Bool
        public var maxAmount: Double

        public init(rule: ApprovalRule) {
            ruleId = rule.id
            actionClass = rule.actionClass
            createdAt = rule.createdAt
            lastUsed = rule.lastUsed
            useCount = rule.useCount
            enabled = rule.enabled
            decision = rule.decision
            hasCap = rule.maxAmount != nil
            maxAmount = rule.maxAmount ?? 0
            // Every field the wire knows about is offered, so a rule can be widened *and*
            // narrowed here — one the card prefilled with a recipient can gain a category.
            fields = ApprovalRule.scopeFields.map { name in
                let stored = rule.scope?[name]
                return Field(
                    id: name,
                    mode: stored?.mode ?? .exact,
                    value: stored?.value ?? "",
                    isAny: stored == nil
                )
            }
        }

        /// The fields that actually constrain something. A field switched to Any, or left
        /// blank, constrains nothing and is dropped rather than saved as an empty pattern.
        var constrained: [Field] {
            fields.filter { !$0.isAny && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        /// A rule has to pin down at least one thing. Otherwise it authorizes a whole action
        /// class outright, which is the blanket grant v1.5 does not offer.
        public var isNarrowEnough: Bool { !constrained.isEmpty }

        public var rule: ApprovalRule {
            let scope = Dictionary(
                uniqueKeysWithValues: constrained.map {
                    ($0.id, ApprovalRuleField(mode: $0.mode, value: $0.value.trimmingCharacters(in: .whitespaces)))
                }
            )
            return ApprovalRule(
                id: ruleId,
                actionClass: actionClass,
                decision: decision,
                scope: scope.isEmpty ? nil : scope,
                maxAmount: hasCap ? maxAmount : nil,
                enabled: enabled,
                createdAt: createdAt,
                lastUsed: lastUsed,
                useCount: useCount
            )
        }
    }
}

/// A rule Yorozu noticed rather than one the user wrote: three matching approvals inside a
/// month, offered back. It is a card and nothing more — Review opens the editor, and only the
/// editor's Save makes it real. "Not now" dismisses it and nothing is stored either way.
public struct RuleProposalCardView: View {
    public let proposal: RuleProposalData
    /// Set once this device has dealt with it, so the card stops offering buttons.
    public let handled: Bool
    public let onSave: (ApprovalRule) -> Void
    public let onDismiss: () -> Void

    @State private var editing: ApprovalRule?
    @State private var dismissed = false

    public init(
        proposal: RuleProposalData,
        handled: Bool = false,
        onSave: @escaping (ApprovalRule) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.proposal = proposal
        self.handled = handled
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
            HStack(spacing: LayoutMetrics.inner) {
                Image(systemName: "lightbulb.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(.tint.opacity(0.14), in: Circle())
                Text("Suggestion")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text("Yorozu noticed you always allow this. Make it a rule?")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(proposal.rule.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("^[\(proposal.approvals) approval](inflect: true) in the last month. Nothing is saved until you say so.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if handled || dismissed {
                Text(dismissed ? String(localized: "Not now") : String(localized: "Reviewed"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 32)
            } else {
                HStack(spacing: LayoutMetrics.inner) {
                    Button("Review") { editing = proposal.rule }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: controlTarget)
                    Button("Not now") {
                        dismissed = true
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: controlTarget)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(LayoutMetrics.cardPadding)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(proposalBackground, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rule suggestion: \(proposal.rule.summary)")
        .sheet(item: $editing) { rule in
            RuleEditorView(rule: rule, title: "New rule") { edited in
                editing = nil
                onSave(edited)
            } onCancel: {
                editing = nil
            }
        }
    }

    private var proposalBackground: Color {
        #if os(iOS)
            Color(.secondarySystemGroupedBackground)
        #else
            Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

/// The rules on this Mac, as both Settings screens list them: what each covers, when it last
/// authorized something, and how often. Shared so the phone's read-only list and the Mac's
/// editable one cannot describe the same rule two different ways.
public struct RuleRowView: View {
    public let rule: ApprovalRule
    /// Nil on the phone, which lists rules without switching them on and off.
    public let onToggle: ((Bool) -> Void)?
    public let onEdit: (() -> Void)?
    @State private var hovering = false

    public init(rule: ApprovalRule, onToggle: ((Bool) -> Void)? = nil, onEdit: (() -> Void)? = nil) {
        self.rule = rule
        self.onToggle = onToggle
        self.onEdit = onEdit
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.inner) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: rule.decision == .never ? "nosign" : "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(rule.decision == .never ? Color.orange : Color.accentColor)
                    Text(rule.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(usage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(rule.isEnabled ? 1 : 0.5)
            Spacer(minLength: 0)
            if let onEdit {
                Button("Edit", action: onEdit).buttonStyle(.borderless)
                    #if os(macOS)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                    #endif
            }
            if let onToggle {
                Toggle("Enabled", isOn: Binding(get: { rule.isEnabled }, set: { onToggle($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enabled")
            }
        }
        .padding(.vertical, 4)
        #if os(macOS)
            .contentShape(.rect)
            .onHover { hovering = $0 }
        #endif
        .accessibilityElement(children: .contain)
    }

    /// What the rule has actually been doing, which is what tells the user whether to keep it.
    private var usage: String {
        let count = rule.useCount ?? 0
        guard count > 0, let last = rule.lastUsed else { return String(localized: "Never used") }
        let when = Date(timeIntervalSince1970: last / 1000)
            .formatted(date: .abbreviated, time: .shortened)
        return "^[Used \(count) time](inflect: true) · last \(when)"
    }
}

extension ApprovalCardView {
    /// The action class as a noun phrase, for the editor and the settings rows.
    public static func actionLabel(_ actionClass: String) -> String {
        let noun = verb(for: actionClass).noun
        return noun.prefix(1).uppercased() + noun.dropFirst()
    }
}
