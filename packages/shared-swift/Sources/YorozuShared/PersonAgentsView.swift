import SwiftUI

/// The same agent identities and ongoing conversations on Mac and iPhone.
public struct PersonAgentsView: View {
    public let model: ChatModel
    private let settings: Bool
    @State private var editor: PersonAgentEditorRoute?
    public init(model: ChatModel, settings: Bool = false) { self.model = model; self.settings = settings }

    public var body: some View {
        Group {
            if model.supportsPersonAgents || !model.canDeliver, let catalog = model.personAgents {
                List {
                    Section {
                        ForEach(catalog.agents) { agent in
                            NavigationLink {
                                if settings { PersonAgentEditorView(model: model, catalog: catalog, agent: agent) }
                                else { PersonAgentConversationView(model: model, agentId: agent.id) }
                            } label: {
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(agent.name).font(.headline)
                                        if catalog.defaultAgentId == agent.id {
                                            Text("Default agent").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(agent.role).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("person-agent-\(agent.id)")
                        }
                        if catalog.agents.isEmpty { Text("Add an agent to start a conversation.").foregroundStyle(.secondary) }
                    }
                    Section {
                        NavigationLink { PersonAgentTeamsView(model: model) } label: { Label("Teams", systemImage: "person.2") }

                    }
                }
                .paperList()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add agent", systemImage: "plus") { editor = PersonAgentEditorRoute(catalog: catalog, agent: nil) }
                            .disabled(!model.canDeliver)
                            .accessibilityIdentifier("person-agent-add")
                    }
                }
                .sheet(item: $editor) { route in
                    NavigationStack { PersonAgentEditorView(model: model, catalog: route.catalog, agent: route.agent, presented: true) }
                        .yorozuTint()
                }
            } else {
                ContentUnavailableView("Agents", systemImage: "person.2", description: Text(
                    model.supportsPersonAgents ? SecretaryUI.localized("Waiting for your Mac to load its agents.") : SecretaryUI.localized("Connect to a Mac that supports agents to manage them here.")))
            }
        }
        .navigationTitle("Agents")
        .yorozuTint()
    }
}

public struct PersonChatsView: View {
    public let model: ChatModel
    public init(model: ChatModel) { self.model = model }
    private var canonicalIds: Set<String> { Set((model.personAgents?.agents ?? []).compactMap(\.conversationId)) }
    public var body: some View {
        List {
            if let secretary = model.threads.first(where: { $0.id == SecretaryUI.threadID }) {
                Section {
                    NavigationLink { PersonConversationView(model: model, initial: secretary) } label: {
                        Label("Yorozu", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            Section("Conversations") {
                ForEach(model.personAgents?.agents ?? []) { agent in
                    NavigationLink { PersonAgentConversationView(model: model, agentId: agent.id) } label: {
                        Label(agent.name, systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            Section("Previous conversations") {
                ForEach(personAgentHistory(model.threads).filter { !canonicalIds.contains($0.id) && $0.id != SecretaryUI.threadID }) { thread in
                    NavigationLink { PersonConversationView(model: model, initial: thread, historical: true) } label: {
                        ThreadRow(thread: thread, agentLabel: thread.personAgentName, working: model.generating.contains(thread.id))
                    }
                }
            }
        }
        .paperList()
        .navigationTitle("Conversations")
    }
}

struct PersonAgentConversationView: View {
    let model: ChatModel
    let agentId: String
    @State private var editor: PersonAgentEditorRoute?
    private var agent: PersonAgent? { model.personAgents?.agents.first { $0.id == agentId } }
    var body: some View {
        Group {
            if let thread = model.personConversation(agentId: agentId) {
                PersonConversationView(model: model, initial: thread)
            } else {
                ContentUnavailableView("Conversation", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Waiting for your Mac to provide this agent’s conversation."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink("History", destination: PersonAgentHistoryView(model: model, agentId: agentId))
                    NavigationLink("Agent exchanges", destination: AgentExchangesView(model: model, agentId: agentId))
                    if let conversation = model.personConversation(agentId: agentId) {
                        NavigationLink("Harness requests", destination: HarnessActionsView(model: model, threadId: conversation.id))
                    }
                    Button("Agent settings", systemImage: "slider.horizontal.3") {
                        if let agent, let catalog = model.personAgents { editor = PersonAgentEditorRoute(catalog: catalog, agent: agent) }
                    }
                    .disabled(agent == nil || !model.supportsPersonAgents)
                } label: { Label("Agent", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $editor) { route in
            NavigationStack { PersonAgentEditorView(model: model, catalog: route.catalog, agent: route.agent, presented: true) }.yorozuTint()
        }
    }
}

struct PersonAgentHistoryView: View {
    let model: ChatModel
    let agentId: String
    private var canonicalId: String? { model.personAgents?.agents.first { $0.id == agentId }?.conversationId }
    var body: some View {
        List {
            ForEach(personAgentHistory(model.threads, agentId: agentId).filter { $0.id != canonicalId }) { thread in
                NavigationLink { PersonConversationView(model: model, initial: thread, historical: true) } label: {
                    ThreadRow(thread: thread, working: model.generating.contains(thread.id))
                }
            }
        }
        .paperList()
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink("Ongoing conversation", destination: PersonAgentConversationView(model: model, agentId: agentId))
            }
        }
    }
}

struct PersonConversationView: View {
    let model: ChatModel
    let initial: ThreadSummary
    var historical = false
    private var thread: ThreadSummary { model.threads.first { $0.id == initial.id } ?? initial }
    var body: some View {
        ChatView(model: model, thread: thread, readOnly: historical)
            .environment(\.secretaryPresentation, thread.id == SecretaryUI.threadID)
            .onAppear { model.openThread = thread.id }
            .onDisappear {
                if model.openThread == thread.id { model.openThread = nil }
                Task { await model.flushCache() }
            }
    }
}

struct PersonAgentControlFeedback: View {
    let model: ChatModel
    let submission: PersonAgentSubmission
    var body: some View {
        if let failure = submission.failure { Text(failure).foregroundStyle(.secondary) }
        else if let result = submission.result(in: model.personAgents) {
            switch result.status {
            case .applied: Label("Saved", systemImage: "checkmark").foregroundStyle(.secondary)
            case .rejected: Text(result.reason ?? SecretaryUI.localized("Your Mac could not save this change.")).foregroundStyle(.secondary)
            case .unknown: Text(result.reason ?? SecretaryUI.localized("The outcome is unconfirmed. Your changes have not been resent.")).foregroundStyle(.secondary)
            }
        } else if submission.operationId != nil {
            Label("Waiting for your Mac…", systemImage: "clock").foregroundStyle(.secondary)
        }
    }
}
