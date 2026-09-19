import SwiftUI
import YorozuShared

/// The Rules tab: every standing decision Yorozu is acting on, what each one covers, what it
/// has actually been doing, and the two things a user needs from this screen — switch one off,
/// or revoke it outright. Editing opens the same sheet the approval card's "Always allow" does,
/// so a rule is only ever written in one place.
///
/// Reads and writes `approval.json` directly. The runtime re-reads that file on every decision,
/// so a rule switched off here stops applying to the next tool call without anything being
/// restarted. See ``ApprovalSettings``.
struct RulesView: View {
    @State private var rules = ApprovalSettings.loadRules()
    @State private var editing: ApprovalRule?
    @State private var confirmingDelete: ApprovalRule?
    @State private var hoveredRuleID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rules let routine work run without asking. They apply to every agent, and last until you revoke them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if rules.isEmpty {
                ContentUnavailableView(
                    "No rules yet",
                    systemImage: "checkmark.seal",
                    description: Text("Choose “Always allow” on an approval card to make one.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(rules) { rule in
                    RuleRowView(
                        rule: rule,
                        onToggle: { enable(rule, $0) },
                        onEdit: { editing = rule }
                    )
                    .contextMenu {
                        Button("Edit…") { editing = rule }
                        Button("Revoke", role: .destructive) { confirmingDelete = rule }
                    }
                    .overlay(alignment: .trailing) {
                        // The switch is the common action, so revoking is the deliberate one:
                        // a second click, past a confirmation, rather than a stray one.
                        Button {
                            confirmingDelete = rule
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Revoke this rule")
                        .accessibilityLabel("Revoke rule")
                        .offset(x: 34)
                        .opacity(hoveredRuleID == rule.id ? 1 : 0)
                        .allowsHitTesting(hoveredRuleID == rule.id)
                    }
                    .contentShape(.rect)
                    .onHover { hoveredRuleID = $0 ? rule.id : nil }
                    Divider()
                }
            }

            // The floor is not a rule and cannot be overridden by one, so it is said here as
            // well as in onboarding: it is the reason a rule sometimes does not fire.
            Text("Yorozu always asks about subscriptions, transfers, securities trades and crypto, whatever rules are saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(.trailing, 34)
        .onAppear { rules = ApprovalSettings.loadRules() }
        .sheet(item: $editing) { rule in
            RuleEditorView(rule: rule, title: "Edit rule") { edited in
                editing = nil
                save { $0.replace(edited) }
            } onCancel: {
                editing = nil
            }
        }
        .confirmationDialog(
            "Revoke this rule?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { rule in
            Button("Revoke", role: .destructive) {
                save { $0.removeAll { $0.id == rule.id } }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: { rule in
            Text("Yorozu will ask again before it does \(rule.summary).")
        }
    }

    private func enable(_ rule: ApprovalRule, _ enabled: Bool) {
        var edited = rule
        edited.enabled = enabled
        save { $0.replace(edited) }
    }

    /// Re-read before writing, because the runtime is keeping `lastUsed` and `useCount` in the
    /// same file and a stale copy of the list would roll those back.
    private func save(_ change: (inout [ApprovalRule]) -> Void) {
        var current = ApprovalSettings.loadRules()
        change(&current)
        ApprovalSettings.saveRules(current)
        rules = current
    }
}

extension [ApprovalRule] {
    /// Puts an edited rule back where it was, or appends it if it is new.
    mutating func replace(_ rule: ApprovalRule) {
        if let index = firstIndex(where: { $0.id == rule.id }) {
            self[index] = rule
        } else {
            append(rule)
        }
    }
}
