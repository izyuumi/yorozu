import AppKit
import SwiftUI
import YorozuShared

/// Which agents are signed in on this Mac, and their setup actions. The runtime
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
            ForEach(agents.indices, id: \.self) { index in
                row(agents[index], model.agentStatus.flatMap(agents[index].status))
            }
            Text("Sign-in and connection checks do not prove the assistant can answer. Send a message to check an actual response.")
                .font(.scaled(.caption)).foregroundStyle(.secondary)
            if model.agentStatusChecking { ProgressView("Checking sign-in…").controlSize(.small) }
            if let failure = model.agentStatusFailure { Text(failure).foregroundStyle(.secondary) }
            Button("Re-check") { model.requestAgentStatus() }
                .disabled(model.agentStatusChecking)
        }
        .task { model.requestAgentStatus() }
    }

    private func row(_ agent: Agent, _ readiness: AgentReadiness?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent.name)
                Text(agent.purpose).font(.scaled(.caption)).foregroundStyle(.secondary)
                Spacer()
                if readiness?.ok == true {
                    Label(agent.login == nil ? String(localized: "Reachable") : String(localized: "Signed in"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(YorozuPalette.sage)
                } else {
                    Text(readiness.map(summary) ?? "Not checked").foregroundStyle(.secondary)
                }
            }
            if readiness?.ok != true {
                Link("Set up \(Text(agent.name))", destination: agent.setup).font(.scaled(.caption))
                if readiness == nil, agent.login == nil {
                    Text("Assistant connection has not been verified by this check.")
                        .font(.scaled(.caption)).foregroundStyle(.secondary)
                }
                if readiness?.reason == .notLoggedIn, let login = agent.login {
                    DisclosureGroup("Sign-in instructions") {
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
                    }
                }
                if let detail = readiness?.detail {
                    DisclosureGroup("Check details") {
                        Text(detail).font(.scaled(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func summary(_ readiness: AgentReadiness) -> LocalizedStringKey {
        switch readiness.reason {
        case .notFound: "Not installed"
        case .notLoggedIn: "Not logged in"
        case .unreachable: "Assistant connection unavailable"
        case nil: "Unavailable"
        }
    }
}
