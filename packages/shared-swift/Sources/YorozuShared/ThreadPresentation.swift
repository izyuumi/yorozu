import Foundation

/// One source for the identity and project context shown before and during a conversation.
/// Older threads without an agent field keep their Yorozu behavior.
struct ThreadPresentation {
    let agent: ThreadAgent
    let agentLabel: String
    let needsFolder: Bool
    let projectPath: String?

    init(thread: ThreadSummary, descriptor: AgentDescriptor? = nil) {
        agent = thread.agent ?? .yorozu
        agentLabel = ThreadAgent.allCases.contains(agent) ? agent.label : descriptor?.label ?? agent.label
        needsFolder = descriptor?.needsFolder ?? agent.needsFolder
        if needsFolder, let path = thread.cwd,
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Directory names can contain leading or trailing spaces. Check emptiness without
            // rewriting the actual location the agent was asked to work in.
            projectPath = path
        } else {
            projectPath = nil
        }
    }

    var projectName: String? {
        projectPath.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
    }

    var composerPlaceholder: String { SecretaryUI.localized("Message \(agentLabel)") }

    var emptyTitle: String {
        needsFolder ? SecretaryUI.localized("Start with \(agentLabel)") : SecretaryUI.localized("Start the conversation")
    }

    var emptyMessage: String {
        guard needsFolder else {
            return agent == .yorozu
                ? SecretaryUI.localized("Ask for anything your Mac can do — files, mail, calendars, or the browser.")
                : SecretaryUI.localized("Ask \(agentLabel) to get started.")
        }
        return projectPath == nil
            ? SecretaryUI.localized("Start a new thread and choose a project folder for this coding agent.")
            : SecretaryUI.localized("Describe a change, ask about the code, or investigate a problem in this project.")
    }
}
