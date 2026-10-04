import SwiftUI

private actor PersonAgentPreviewTransport: ChatTransport {
    func connect() -> AsyncStream<TransportUpdate> {
        AsyncStream { stream in
            stream.yield(.state(.paired))
            stream.yield(.ownerOnline(true))
            stream.yield(.compatibility(.compatible(version: 1, capabilities: ["person-agents-v1"])))
            stream.yield(.event(YorozuEvent(id: "preview-agents", threadId: "", ts: 1, agentId: "main",
                payload: .threadList(ThreadListData(threads: [], personAgents: Self.catalog)))))
        }
    }
    func send(_ event: YorozuEvent) async throws {}
    func close() {}
    static var catalog: PersonAgentRegistry {
        let agents = [
            PersonAgent(id: "ada", name: "Ada", role: "Keep notes and help with daily work", pluginId: .hermes,
                workspace: "/tmp/yorozu-preview/ada/workspace", memoryDir: "/tmp/yorozu-preview/ada/memory", allowedTools: [.file, .memory, .delegation]),
            PersonAgent(id: "bea", name: "Bea", role: "Research and plan", pluginId: .openclaw,
                workspace: "/tmp/yorozu-preview/bea/workspace", memoryDir: "/tmp/yorozu-preview/bea/memory", allowedTools: [.web, .memory]),
        ]
        return PersonAgentRegistry(revision: 1, defaultAgentId: "ada", agents: agents, journalRevision: 0)
    }
}

private struct PersonAgentPreview: View {
    @State private var model = ChatModel(transport: PersonAgentPreviewTransport())
    var body: some View {
        NavigationStack { PersonAgentsView(model: model) }
            .task { model.start() }
            .onDisappear { model.close() }
    }
}

#Preview("Agents") { PersonAgentPreview() }

#Preview("Agent settings") {
    NavigationStack {
        PersonAgentEditorView(model: ChatModel(transport: PersonAgentPreviewTransport()),
            catalog: PersonAgentPreviewTransport.catalog, agent: PersonAgentPreviewTransport.catalog.agents[0])
    }
}

#Preview("Agents unavailable") {
    NavigationStack { PersonAgentsView(model: ChatModel(transport: PersonAgentPreviewTransport())) }
}
