import Foundation

/// One source for the identity and project context shown before and during a conversation.
/// Older threads without a recognized agent keep their existing Yorozu behavior.
struct ThreadPresentation {
    let agent: ThreadAgent
    let projectPath: String?

    init(thread: ThreadSummary) {
        agent = thread.agent ?? .yorozu
        if agent.needsFolder, let path = thread.cwd,
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

    var composerPlaceholder: String { String(localized: "Message \(agent.label)") }

    var emptyTitle: String {
        agent.needsFolder ? String(localized: "Start with \(agent.label)") : String(localized: "Start the conversation")
    }

    var emptyMessage: String {
        guard agent.needsFolder else {
            return String(localized: "Ask for anything your Mac can do — files, mail, calendars, or the browser.")
        }
        return projectPath == nil
            ? String(localized: "Start a new thread and choose a project folder for this coding agent.")
            : String(localized: "Describe a change, ask about the code, or investigate a problem in this project.")
    }
}
