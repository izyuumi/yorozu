import SwiftUI

struct HarnessActionCard: View {
    let model: ChatModel
    let action: HarnessActionData
    @State private var text = ""
    private var status: HarnessActionStatusData? { model.harnessActionStatus(for: action) }
    private var agentName: String { model.personAgents?.agents.first { $0.id == action.origin.agentId }?.name ?? action.origin.agentId }
    private var harnessName: String { model.personAgents?.harnesses?.first { $0.id == action.origin.pluginId }?.label ?? action.origin.pluginId.rawValue }

    var body: some View {
        VStack(alignment: .leading) {
            Label("\(agentName) · \(harnessName)", systemImage: "hand.raised")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(action.title).font(.headline)
            if let description = action.text { Text(description).textSelection(.enabled) }
            if action.state == .pending {
                ForEach(action.choices, id: \.id) { choice in
                    Button(choice.label) { model.answerHarnessAction(action, choiceId: choice.id) }
                        .disabled(!model.canAnswerHarnessAction(action))
                        .accessibilityIdentifier("harness-action-\(action.requestId)-\(choice.id)")
                }
                if action.allowText == true {
                    TextField("Answer", text: $text, axis: .vertical)
                    Button("Send answer") {
                        if model.answerHarnessAction(action, text: text) != nil { text = "" }
                    }
                    .disabled(!model.canAnswerHarnessAction(action) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let ui = action.ui {
                    Button(ui.label, systemImage: "arrow.up.forward.app") {
                        model.answerHarnessAction(action, uiTargetId: ui.targetId)
                    }
                    .disabled(!model.canAnswerHarnessAction(action))
                }
            }
            if action.state == .cancelled { Text("Request cancelled").foregroundStyle(.secondary) }
            else if action.state == .resolved { Text("Resolved by the harness").foregroundStyle(.secondary) }
            else if let status {
                Text(statusLabel(status.status)).font(.footnote).foregroundStyle(.secondary)
                if let reason = status.reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
            } else if !model.canDeliver {
                Text("Waiting for Mac").font(.footnote).foregroundStyle(.secondary)
            } else if !model.canAnswerHarnessAction(action) {
                Text("Waiting for the harness to confirm the response").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .yorozuPaperCard(padding: LayoutMetrics.inner)
    }

    private func statusLabel(_ status: HarnessActionStatusData.Status) -> String {
        switch status {
        case .requested: SecretaryUI.localized("Waiting for the harness")
        case .applied: SecretaryUI.localized("Response applied by the harness")
        case .rejected: SecretaryUI.localized("Response rejected by the harness")
        case .noLongerNeeded: SecretaryUI.localized("Request no longer needed")
        case .unknown: SecretaryUI.localized("Response outcome unconfirmed")
        }
    }
}

struct HarnessActionPresentationView: View {
    let model: ChatModel
    let threadId: String
    private var pending: [YorozuEvent] {
        model.harnessActions(in: threadId).filter {
            guard case .harnessAction(let action) = $0.payload else { return false }
            let status = model.harnessActionStatus(for: action)?.status
            return action.state == .pending && status != .applied && status != .noLongerNeeded
        }
    }
    var body: some View {
        if let first = pending.first, case .harnessAction(let action) = first.payload {
            VStack(alignment: .leading) {
                HarnessActionCard(model: model, action: action).id(first.id)
                if pending.count > 1 {
                    NavigationLink("All harness requests (\(pending.count))", destination: HarnessActionsView(model: model, threadId: threadId))
                }
            }
            .padding(.horizontal)
        }
    }
}

struct HarnessActionsView: View {
    let model: ChatModel
    let threadId: String
    var body: some View {
        List {
            ForEach(model.harnessActions(in: threadId), id: \.id) { event in
                if case .harnessAction(let action) = event.payload {
                    HarnessActionCard(model: model, action: action).id(event.id)
                }
            }
        }
        .paperList()
        .navigationTitle("Harness requests")
    }
}
