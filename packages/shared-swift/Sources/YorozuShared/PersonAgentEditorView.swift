import SwiftUI

struct PersonAgentEditorRoute: Identifiable {
    let id = UUID()
    let catalog: PersonAgentRegistry
    let agent: PersonAgent?
}

struct PersonAgentEditorView: View {
    let model: ChatModel
    let catalog: PersonAgentRegistry
    let presented: Bool
    @State private var draft: PersonAgentEditorDraft
    @State private var submission = PersonAgentSubmission()
    @Environment(\.dismiss) private var dismiss

    init(model: ChatModel, catalog: PersonAgentRegistry, agent: PersonAgent? = nil, presented: Bool = false) {
        self.model = model; self.catalog = catalog; self.presented = presented
        _draft = State(initialValue: PersonAgentEditorDraft(catalog: catalog, agent: agent))
    }
    private var selectedHarness: PersonAgentHarnessDescriptor? { catalog.harnesses?.first { $0.id == draft.plugin } }
    private var changedElsewhere: Bool { model.personAgents?.revision != draft.revision }
    var body: some View {
        Form {
            Section("Agent") {
                TextField("Name", text: $draft.name).accessibilityIdentifier("person-agent-name")
                TextField("Role", text: $draft.role, axis: .vertical).accessibilityIdentifier("person-agent-role")
            }
            Section("Harness") {
                Picker("Harness", selection: $draft.plugin) {
                    Text("Choose a harness").tag(PersonAgentPlugin?.none)
                    ForEach(catalog.harnesses ?? [], id: \.id) { harness in
                        Text(harness.label).tag(Optional(harness.id)).disabled(!harness.available)
                    }
                    if let selected = draft.plugin, catalog.harnesses?.contains(where: { $0.id == selected }) != true {
                        Text("Saved harness (unavailable)").tag(Optional(selected))
                    }
                }
                .accessibilityIdentifier("person-agent-harness")
                Picker("Hosting", selection: $draft.runtimeMode) {
                    Text("Run on this Mac").tag(PersonAgentRuntime.Mode.managed)
                        .disabled(selectedHarness?.modes.contains(.managed) != true)
                    Text("Connect to a running agent").tag(PersonAgentRuntime.Mode.connected)
                        .disabled(selectedHarness?.modes.contains(.connected) != true)
                }
                if draft.runtimeMode == .connected {
                    Picker("Connection", selection: $draft.runtimeConnectionId) {
                        Text("Choose a running agent").tag("")
                        ForEach((catalog.connections ?? []).filter { $0.pluginId == draft.plugin }, id: \.id) { connection in
                            Text(connection.label).tag(connection.id).disabled(!connection.available)
                        }
                        if !draft.runtimeConnectionId.isEmpty,
                           catalog.connections?.contains(where: { $0.id == draft.runtimeConnectionId && $0.pluginId == draft.plugin }) != true {
                            Text("Saved connection (unavailable)").tag(draft.runtimeConnectionId)
                        }
                    }
                    Text("The connected harness keeps control of its process, memory and sign-in. Disconnecting leaves it running.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    TextField("Model", text: $draft.model)
                    Picker("ChatGPT account", selection: $draft.connection) {
                        Text("Select an account").tag("")
                        ForEach(Array((model.siwcAccounts?.accounts ?? []).enumerated()), id: \.element.id) { index, account in
                            Text("Account \(index + 1)").tag(account.id)
                                .disabled(account.phase != .ready || !account.planUse)
                        }
                        if !draft.connection.isEmpty, model.siwcAccounts?.accounts.contains(where: { $0.id == draft.connection }) != true {
                            Text("Saved account (unavailable)").tag(draft.connection)
                        }
                    }
                    .accessibilityIdentifier("person-agent-account")
                }
                if let reason = selectedHarness?.unavailableReason {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
                if catalog.harnesses == nil {
                    Text("Reconnect to a Mac that publishes available harnesses before adding an agent.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(draft.editableTools, id: \.self) { tool in
                    Toggle(tool.label, isOn: Binding(get: { draft.tools.contains(tool) }, set: {
                        if $0 { draft.tools.insert(tool) } else { draft.tools.remove(tool) }
                    }))
                }
            } header: { Text("Access") } footer: {
                Text("Your Mac confirms available access before saving.")
                if draft.editableTools.contains(.memory) {
                    Text("Memory is private to this agent. Ask it in its conversation to save, share or revoke a note. Sharing requires your confirmation in a harness request card.")
                }
            }
            Section {
                ForEach(draft.directories.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        TextField("Folder path", text: $draft.directories[index].path)
                        HStack {
                            Picker("Access", selection: $draft.directories[index].access) {
                                Text("Read").tag(PersonAgentDirectoryGrant.Access.read)
                                Text("Read and write").tag(PersonAgentDirectoryGrant.Access.write)
                            }
                            Button("Remove folder", systemImage: "minus.circle") { draft.directories.remove(at: index) }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                Button("Add folder", systemImage: "plus") {
                    draft.directories.append(PersonAgentDirectoryGrant(path: "", access: .read))
                }
                .disabled(draft.directories.count >= 64)
            } header: { Text("Folders on your Mac") } footer: {
                Text("Only folders already shared by your Mac are available.")
            }
            if let original = draft.original {
                Section("Workspace") { Text(original.workspace).font(.callout).textSelection(.enabled) }
                Section("Teams") {
                    ForEach(catalog.teams.filter { $0.agentIds.contains(original.id) }) { team in Text(team.name) }
                    NavigationLink("Manage teams") { PersonAgentTeamsView(model: model) }
                }
            }
            if changedElsewhere { Section { Text("Agent settings changed. Reopen this editor to use the latest settings.").foregroundStyle(.secondary) } }
            Section { PersonAgentControlFeedback(model: model, submission: submission) }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.original == nil ? SecretaryUI.localized("Add agent") : SecretaryUI.localized("Agent settings"))
        .toolbar {
            if presented { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(draft.request == nil || changedElsewhere || !model.canDeliver || !model.supportsPersonAgents || submission.blocksSubmission(in: model.personAgents))
                    .accessibilityIdentifier("person-agent-save")
            }
        }
        .onChange(of: model.personAgents?.lastControlResult) { _, _ in
            if submission.result(in: model.personAgents)?.status == .applied { dismiss() }
        }
        .onAppear { if draft.runtimeMode == .managed { model.requestSiwcAccountStatus() } }
        .onChange(of: draft.plugin) { _, _ in
            draft.runtimeConnectionId = ""
            if selectedHarness?.modes.contains(draft.runtimeMode) != true {
                draft.runtimeMode = selectedHarness?.modes.first ?? .managed
            }
        }
    }
    private func save() {
        guard let request = draft.request else { return }
        submission.submit(request, to: model)
    }
}

private extension PersonAgentTool {
    var label: String {
        switch self {
        case .file: SecretaryUI.localized("Files")
        case .terminal: SecretaryUI.localized("Run commands")
        case .delegation: SecretaryUI.localized("Delegate tasks")
        case .memory: SecretaryUI.localized("Memory")
        case .web: SecretaryUI.localized("Web")
        case .browser: SecretaryUI.localized("Browser")
        case .team: SecretaryUI.localized("Work with teammates")
        case .computer: SecretaryUI.localized("Use the computer")
        }
    }
}

struct PersonAgentTeamsView: View {
    let model: ChatModel
    @State private var editor: TeamEditorRoute?
    var body: some View {
        List {
            if let catalog = model.personAgents {
                ForEach(catalog.teams) { team in
                    Button { editor = TeamEditorRoute(catalog: catalog, team: team) } label: {
                        VStack(alignment: .leading) {
                            Text(team.name).foregroundStyle(.primary)
                            Text(catalog.agents.filter { team.agentIds.contains($0.id) }.map(\.name).joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if catalog.teams.isEmpty { Text("Choose the agents who work together.").foregroundStyle(.secondary) }
            }
        }
        .paperList()
        .navigationTitle("Teams")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add team", systemImage: "plus") {
                    if let catalog = model.personAgents { editor = TeamEditorRoute(catalog: catalog, team: nil) }
                }
                .disabled(!model.canDeliver || model.personAgents?.agents.isEmpty != false)
            }
        }
        .sheet(item: $editor) { route in
            NavigationStack { PersonAgentTeamEditor(model: model, route: route) }.yorozuTint()
        }
    }
}
private struct TeamEditorRoute: Identifiable {
    let id = UUID()
    let catalog: PersonAgentRegistry
    let team: PersonAgentTeam?
}
private struct PersonAgentTeamEditor: View {
    let model: ChatModel
    let route: TeamEditorRoute
    @State private var name: String
    @State private var members: Set<String>
    @State private var submission = PersonAgentSubmission()
    @Environment(\.dismiss) private var dismiss
    init(model: ChatModel, route: TeamEditorRoute) {
        self.model = model; self.route = route
        _name = State(initialValue: route.team?.name ?? "")
        _members = State(initialValue: Set(route.team?.agentIds ?? []))
    }
    private var request: PersonAgentControlData {
        let ids = route.catalog.agents.filter { members.contains($0.id) }.map(\.id)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let action: PersonAgentControlAction = route.team.map { .updateTeam(teamId: $0.id, patch: PersonAgentTeamPatch(name: name, agentIds: ids)) }
            ?? .createTeam(PersonAgentTeamInput(name: name, agentIds: ids))
        return PersonAgentControlData(expectedRevision: route.catalog.revision, action: action)
    }
    var body: some View {
        Form {
            Section { TextField("Team name", text: $name) }
            Section("Agents") {
                ForEach(route.catalog.agents) { agent in
                    Toggle(agent.name, isOn: Binding(get: { members.contains(agent.id) }, set: {
                        if $0 { members.insert(agent.id) } else { members.remove(agent.id) }
                    }))
                }
            }
            Section { PersonAgentControlFeedback(model: model, submission: submission) }
        }
        .formStyle(.grouped)
        .navigationTitle(route.team == nil ? SecretaryUI.localized("Add team") : SecretaryUI.localized("Team settings"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { submission.submit(request, to: model) }
                    .disabled(!request.isValid || !model.canDeliver || !model.supportsPersonAgents || model.personAgents?.revision != route.catalog.revision || submission.blocksSubmission(in: model.personAgents))
            }
        }
        .onChange(of: model.personAgents?.lastControlResult) { _, _ in
            if submission.result(in: model.personAgents)?.status == .applied { dismiss() }
        }
    }
}
