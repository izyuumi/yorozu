import SwiftUI

/// The same host-owned agents and conversations on Mac and iPhone.
public struct PersonAgentsView: View {
    public let model: ChatModel
    private let settings: Bool
    @State private var editor: PersonAgentEditorRoute?
    public init(model: ChatModel, settings: Bool = false) { self.model = model; self.settings = settings }

    public var body: some View {
        Group {
            if model.supportsPersonAgents, let catalog = model.personAgents {
                List {
                    Section {
                        ForEach(catalog.agents) { agent in
                            NavigationLink {
                                if settings { PersonAgentEditorView(model: model, catalog: catalog, agent: agent) }
                                else { PersonAgentChatsView(model: model, agentId: agent.id) }
                            } label: {
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(agent.name).font(.headline)
                                        if catalog.defaultAgentId == agent.id {
                                            Text("Default for new chats").font(.caption).foregroundStyle(.secondary)
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
                        if catalog.journalRevision != nil {
                            NavigationLink {
                                PersonAgentMemoryView(model: model, catalog: catalog)
                            } label: { Label("Shared preferences", systemImage: "bookmark") }
                        }
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
    @State private var newThread: String?
    public init(model: ChatModel) { self.model = model }
    public var body: some View {
        List {
            if let secretary = model.threads.first(where: { $0.id == SecretaryUI.threadID }) {
                Section {
                    NavigationLink { PersonConversationView(model: model, initial: secretary) } label: {
                        Label("Yorozu", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            Section("Chats") {
                ForEach(personAgentChats(model.threads).filter { $0.id != SecretaryUI.threadID }) { thread in
                    NavigationLink { PersonConversationView(model: model, initial: thread) } label: {
                        ThreadRow(thread: thread, agentLabel: thread.personAgentName, working: model.generating.contains(thread.id))
                    }
                }
            }
        }
        .paperList()
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(model.personAgents?.agents ?? []) { agent in
                        Button(agent.name) { newThread = model.newPersonThread(agentId: agent.id)?.id }
                    }
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                } primaryAction: {
                    newThread = model.newPersonThread()?.id
                }
                .disabled(!model.canDeliver || model.personAgents?.agents.isEmpty != false)
                .accessibilityIdentifier("person-chat-new")
            }
        }
        .navigationDestination(item: $newThread) { id in
            if let thread = model.threads.first(where: { $0.id == id }) { PersonConversationView(model: model, initial: thread) }
        }
    }
}

struct PersonAgentChatsView: View {
    let model: ChatModel
    let agentId: String
    @State private var newThread: String?
    @State private var editor: PersonAgentEditorRoute?
    @State private var submission = PersonAgentSubmission()
    private var agent: PersonAgent? { model.personAgents?.agents.first { $0.id == agentId } }
    var body: some View {
        List {
            if let agent, let catalog = model.personAgents {
                Section {
                    Text(agent.role).foregroundStyle(.secondary)
                    if catalog.defaultAgentId == agent.id { Label("Default for new chats", systemImage: "checkmark") }
                    else {
                        Button("Use as default for new chats") {
                            submission.submit(PersonAgentControlData(expectedRevision: catalog.revision,
                                action: .setDefault(agentId: agent.id)), to: model)
                        }
                        .disabled(!model.canDeliver || submission.blocksSubmission(in: catalog))
                    }
                    PersonAgentControlFeedback(model: model, submission: submission)
                }
                Section("Chats") {
                    Button("New chat", systemImage: "square.and.pencil") { newThread = model.newPersonThread(agentId: agent.id)?.id }
                        .disabled(!model.canDeliver || !model.supportsPersonAgents)
                        .accessibilityIdentifier("person-agent-new-chat")
                    ForEach(personAgentChats(model.threads, agentId: agent.id)) { thread in
                        NavigationLink { PersonConversationView(model: model, initial: thread) } label: {
                            ThreadRow(thread: thread, working: model.generating.contains(thread.id))
                        }
                    }
                }
                if catalog.journalRevision != nil {
                    Section {
                        NavigationLink {
                            PersonAgentMemoryView(model: model, catalog: catalog, agent: agent)
                        } label: { Label("Preferences and shared knowledge", systemImage: "bookmark") }
                    }
                }
            }
        }
        .paperList()
        .navigationTitle(agent?.name ?? SecretaryUI.localized("Agent"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Agent settings", systemImage: "slider.horizontal.3") {
                    if let agent, let catalog = model.personAgents { editor = PersonAgentEditorRoute(catalog: catalog, agent: agent) }
                }
                    .disabled(agent == nil || !model.supportsPersonAgents)
            }
        }
        .sheet(item: $editor) { route in
            NavigationStack { PersonAgentEditorView(model: model, catalog: route.catalog, agent: route.agent, presented: true) }.yorozuTint()
        }
        .navigationDestination(item: $newThread) { id in
            if let thread = model.threads.first(where: { $0.id == id }) { PersonConversationView(model: model, initial: thread) }
        }
    }
}

struct PersonConversationView: View {
    let model: ChatModel
    let initial: ThreadSummary
    private var thread: ThreadSummary { model.threads.first { $0.id == initial.id } ?? initial }
    var body: some View {
        ChatView(model: model, thread: thread)
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
