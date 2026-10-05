import SwiftUI

/// Harness-to-harness exchanges are inspectable here, outside the user's ongoing conversation.
struct AgentExchangesView: View {
    let model: ChatModel
    let agentId: String
    private var threads: [ThreadSummary] {
        model.threads.filter {
            guard let exchange = $0.personAgentExchange else { return false }
            return exchange.fromAgentId == agentId || exchange.toAgentId == agentId
        }.sorted { $0.lastActivity > $1.lastActivity }
    }
    var body: some View {
        List {
            ForEach(threads) { thread in
                NavigationLink { AgentExchangeDetailView(model: model, thread: thread) } label: {
                    if let exchange = thread.personAgentExchange {
                        Label("\(name(exchange.fromAgentId)) → \(name(exchange.toAgentId))", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            if threads.isEmpty { Text("No agent exchanges yet.").foregroundStyle(.secondary) }
        }
        .paperList()
        .navigationTitle("Agent exchanges")
    }
    private func name(_ id: String) -> String { model.personAgents?.agents.first { $0.id == id }?.name ?? id }
}

struct AgentExchangeDetailView: View {
    let model: ChatModel
    let thread: ThreadSummary
    private var events: [YorozuEvent] { model.timeline(thread.id).events }
    var body: some View {
        List {
            ForEach(events, id: \.id) { event in
                if case .agentExchange(let message) = event.payload,
                   message.exchangeId == thread.personAgentExchange?.exchangeId {
                    VStack(alignment: .leading) {
                        Text("\(name(message.fromAgentId)) → \(name(message.toAgentId))").font(.headline)
                        Text(message.text).textSelection(.enabled)
                        if let status = status(for: message) {
                            Text("Delivery: \(status.delivery.rawValue)").font(.footnote).foregroundStyle(.secondary)
                            Text("Execution: \(status.execution.rawValue)").font(.footnote).foregroundStyle(.secondary)
                            if let reason = status.reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                        } else {
                            Text("Delivery and execution unconfirmed").font(.footnote).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Origin") {
                            Text("Harness: \(message.origin.pluginId.rawValue)")
                            Text("Conversation: \(message.origin.conversationId)")
                            Text("Session: \(message.origin.sessionId)")
                            Text("Binding: \(message.origin.bindingEpoch)")
                            Text("Delivery: \(message.deliveryId)")
                        }
                        .font(.footnote).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .paperList()
        .navigationTitle("Agent exchange")
        .onAppear { model.openThread = thread.id }
        .onDisappear {
            if model.openThread == thread.id { model.openThread = nil }
            Task { await model.flushCache() }
        }
    }
    private func name(_ id: String) -> String { model.personAgents?.agents.first { $0.id == id }?.name ?? id }
    private func status(for message: AgentExchangeData) -> AgentExchangeStatusData? {
        events.reversed().compactMap {
            guard case .agentExchangeStatus(let status) = $0.payload,
                  status.exchangeId == message.exchangeId, status.messageId == message.messageId,
                  status.deliveryId == message.deliveryId else { return nil }
            return status
        }.first
    }
}
