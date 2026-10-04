import SwiftUI

/// Preferences and knowledge contain only text the person explicitly chooses to save.
struct PersonAgentMemoryView: View {
    let model: ChatModel
    let catalog: PersonAgentRegistry
    var agent: PersonAgent?
    @State private var sharing = false
    @State private var text = ""
    @State private var recipients: Set<String> = []
    @State private var submission = PersonAgentSubmission()
    private var request: PersonAgentControlData? {
        guard let journal = catalog.journalRevision else { return nil }
        let action: PersonAgentControlAction
        if sharing, let agent {
            action = .shareKnowledge(PersonAgentSharedKnowledge(fromAgentId: agent.id,
                toAgentIds: catalog.agents.filter { recipients.contains($0.id) }.map(\.id), text: text), expectedJournalRevision: journal)
        } else {
            let preference: PersonAgentPreference = agent.map { .agent($0.id, text: text) } ?? .allAgents(text: text)
            action = .remember(preference, expectedJournalRevision: journal)
        }
        let request = PersonAgentControlData(expectedRevision: catalog.revision, action: action)
        return request.isValid ? request : nil
    }
    var body: some View {
        Form {
            if agent != nil {
                Section {
                    Picker("Save as", selection: $sharing) {
                        Text("Preference").tag(false)
                        Text("Shared knowledge").tag(true)
                    }
                }
            }
            Section {
                TextField(sharing ? SecretaryUI.localized("Knowledge to share") : SecretaryUI.localized("Preference to remember"), text: $text, axis: .vertical)
                    .accessibilityIdentifier("person-agent-memory-text")
            } footer: {
                if sharing { Text("Share only the text you write here.") }
                else if let agent { Text("Remember this for \(agent.name).") }
                else { Text("Remember this for all agents.") }
            }
            if sharing {
                Section("Share with") {
                    ForEach(catalog.agents.filter { $0.id != agent?.id }) { target in
                        Toggle(target.name, isOn: Binding(get: { recipients.contains(target.id) }, set: {
                            if $0 { recipients.insert(target.id) } else { recipients.remove(target.id) }
                        }))
                    }
                }
            }
            Section { PersonAgentControlFeedback(model: model, submission: submission) }
            if model.personAgents?.journalRevision != catalog.journalRevision || model.personAgents?.revision != catalog.revision {
                Section { Text("Saved preferences or agent settings changed. Reopen this page before saving.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(agent?.name ?? SecretaryUI.localized("Shared preferences"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let request else { return }
                    submission.submit(request, to: model)
                }
                .disabled(request == nil || !model.canDeliver || !model.supportsPersonAgents ||
                    model.personAgents?.revision != catalog.revision || model.personAgents?.journalRevision != catalog.journalRevision ||
                    submission.blocksSubmission(in: model.personAgents))
            }
        }
    }
}
