import Foundation

/// An editor captures the revision it opened on. Host roots and credentials never enter it.
struct PersonAgentEditorDraft: Equatable {
    let revision: Int
    let catalog: PersonAgentRegistry
    let original: PersonAgent?
    var name: String
    var role: String
    var plugin: PersonAgentPlugin?
    var runtimeMode: PersonAgentRuntime.Mode
    var runtimeConnectionId: String
    var model: String
    var connection: String
    var tools: Set<PersonAgentTool>
    var directories: [PersonAgentDirectoryGrant]

    init(catalog: PersonAgentRegistry, agent: PersonAgent? = nil) {
        revision = catalog.revision; self.catalog = catalog; original = agent
        name = agent?.name ?? ""; role = agent?.role ?? ""
        plugin = agent?.pluginId ?? catalog.defaultHarnessId
        runtimeMode = agent?.runtime?.mode ?? .managed
        runtimeConnectionId = agent?.runtime?.connectionId ?? ""
        model = agent?.model ?? ""; connection = agent?.accountBindingId ?? ""
        tools = Set(agent?.allowedTools ?? [.file])
        directories = agent?.directories ?? []
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var request: PersonAgentControlData? {
        guard let plugin else { return nil }
        // Saved configurations stay inspectable on older hosts. New or changed bindings must
        // be an effective choice the current host published, never an assumed plugin default.
        let bindingChanged = original == nil || original?.pluginId != plugin ||
            (original?.runtime?.mode ?? .managed) != runtimeMode ||
            (original?.runtime?.connectionId ?? "") != runtimeConnectionId
        if bindingChanged {
            guard catalog.harnesses?.contains(where: {
                $0.id == plugin && $0.available && $0.modes.contains(runtimeMode)
            }) == true else { return nil }
            if runtimeMode == .connected {
                guard catalog.connections?.contains(where: {
                    $0.id == runtimeConnectionId && $0.pluginId == plugin && $0.available
                }) == true else { return nil }
            }
        }
        let runtime = PersonAgentRuntime(mode: runtimeMode,
            connectionId: runtimeMode == .connected ? runtimeConnectionId : nil)
        let model = trimmed(model), connection = trimmed(connection)
        let tools = PersonAgentTool.allCases.filter { self.tools.contains($0) }
        let action: PersonAgentControlAction
        if let original {
            var clear: [PersonAgentPatch.Clear] = []
            if original.model != nil && model.isEmpty { clear.append(.model) }
            if original.accountBindingId != nil && connection.isEmpty { clear.append(.accountBindingId) }
            action = .update(agentId: original.id, patch: PersonAgentPatch(name: trimmed(name), role: trimmed(role),
                pluginId: bindingChanged ? plugin : nil, model: model.isEmpty ? nil : model,
                accountBindingId: connection.isEmpty ? nil : connection, runtime: bindingChanged ? runtime : nil, allowedTools: tools, directories: directories,
                clear: clear.isEmpty ? nil : clear))
        } else {
            action = .create(PersonAgentInput(name: trimmed(name), role: trimmed(role), pluginId: plugin,
                model: model.isEmpty ? nil : model, accountBindingId: connection.isEmpty ? nil : connection,
                runtime: runtime, allowedTools: tools, directories: directories))
        }
        let data = PersonAgentControlData(expectedRevision: revision, action: action)
        return data.isValid ? data : nil
    }
}

/// Only the result for the submitted operation can acknowledge a settings change.
struct PersonAgentSubmission: Equatable {
    var operationId: String?
    var failure: String?
    func result(in catalog: PersonAgentRegistry?) -> PersonAgentControlResult? {
        guard let operationId, catalog?.lastControlResult?.operationId == operationId else { return nil }
        return catalog?.lastControlResult
    }
    func blocksSubmission(in catalog: PersonAgentRegistry?) -> Bool {
        guard operationId != nil else { return false }
        return result(in: catalog)?.status != .rejected
    }
    @MainActor mutating func submit(_ request: PersonAgentControlData, to model: ChatModel) {
        guard !blocksSubmission(in: model.personAgents) else { return }
        guard model.personAgents?.revision == request.expectedRevision else {
            failure = SecretaryUI.localized("Agent settings changed. Reopen this editor to use the latest settings.")
            return
        }
        switch request.action {
        case .remember(_, let revision), .shareKnowledge(_, let revision):
            guard model.personAgents?.journalRevision == revision else {
                failure = SecretaryUI.localized("Saved preferences or agent settings changed. Reopen this page before saving.")
                return
            }
        default: break
        }
        operationId = model.controlPersonAgents(request)
        failure = operationId == nil ? SecretaryUI.localized("Reconnect to your Mac to save these settings.") : nil
    }
}

func personAgentChats(_ threads: [ThreadSummary], agentId: String? = nil) -> [ThreadSummary] {
    visibleThreads(threads).filter {
        $0.harnessTask == nil && $0.personAgentExchange == nil && $0.personAgentId != nil && (agentId == nil || $0.personAgentId == agentId)
    }
}

/// Historical topic threads, including archived history, remain inspectable after migration.
func personAgentHistory(_ threads: [ThreadSummary], agentId: String? = nil) -> [ThreadSummary] {
    threads.filter {
        $0.harnessTask == nil && $0.personAgentExchange == nil && $0.personAgentId != nil && (agentId == nil || $0.personAgentId == agentId)
    }.sorted { $0.lastActivity > $1.lastActivity }
}
