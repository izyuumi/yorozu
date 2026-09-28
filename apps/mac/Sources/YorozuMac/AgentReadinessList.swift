import AppKit
import SwiftUI
import YorozuShared

/// Which agents would answer on this Mac, and the one step each needs if not. The runtime
/// answers, not this app: a thread runs with the runtime's `PATH` and logins.
///
/// Nothing here gates anything. Setup finishes whatever this says; it only turns "set up the
/// agent you use" into something the user can act on.
struct AgentReadinessList: View {
    var model: ChatModel

    private struct Agent {
        let name: LocalizedStringKey
        let purpose: LocalizedStringKey
        /// A stable redirect on the site, so a shipped app never holds a vendor's URL.
        let setup: URL
        let login: String?
        let status: (AgentStatusData) -> AgentReadiness?
    }

    private let agents = [
        Agent(name: "OpenClaw", purpose: "Assistant chats",
              setup: URL(string: "https://yorozu.yumi.to/setup/openclaw")!, login: nil, status: \.openclaw),
        Agent(name: "Claude Code", purpose: "Coding threads",
              setup: URL(string: "https://yorozu.yumi.to/setup/claude")!, login: "claude auth login", status: \.claude),
        Agent(name: "Codex", purpose: "Coding threads",
              setup: URL(string: "https://yorozu.yumi.to/setup/codex")!, login: "codex login", status: \.codex),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status = model.agentStatus {
                ForEach(agents.indices, id: \.self) { index in
                    // An agent the runtime does not have (no Gateway) is not listed as broken.
                    if let readiness = agents[index].status(status) {
                        row(agents[index], readiness)
                    }
                }
            } else {
                ProgressView("Checking agents…").controlSize(.small)
            }
            Button("Re-check") { model.requestAgentStatus() }
                .disabled(model.agentStatus == nil)
        }
        .task { model.requestAgentStatus() }
    }

    private func row(_ agent: Agent, _ readiness: AgentReadiness) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent.name)
                Text(agent.purpose).font(.scaled(.caption)).foregroundStyle(.secondary)
                Spacer()
                if readiness.ok {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(YorozuPalette.sage)
                } else {
                    Text(summary(readiness)).foregroundStyle(.secondary)
                }
            }
            if !readiness.ok {
                if readiness.reason == .notLoggedIn, let login = agent.login {
                    HStack {
                        Text("In Terminal, run")
                        Text(login).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(login, forType: .string)
                        }
                        .controlSize(.small)
                        .accessibilityLabel(Text("Copy \(login)"))
                    }
                    .font(.scaled(.caption))
                } else {
                    Link("Set up \(Text(agent.name))", destination: agent.setup).font(.scaled(.caption))
                }
                if let detail = readiness.detail {
                    Text(detail).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func summary(_ readiness: AgentReadiness) -> LocalizedStringKey {
        switch readiness.reason {
        case .notFound: "Not installed"
        case .notLoggedIn: "Not logged in"
        case .unreachable: "Gateway not running"
        case nil: "Unavailable"
        }
    }
}
