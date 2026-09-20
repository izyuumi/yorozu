import SwiftUI

/// Test harness only: which folder a coding-agent picker opens on, so a screenshot can show
/// the second step without a tap.
@MainActor public enum NewThreadShowcase {
    public static var agent: ThreadAgent?
}

/// Who should answer a new thread, and — for a coding agent — where. Two steps at most, and a
/// recent folder is two taps from the `+`: the agent, then the folder at the top of its list.
///
/// A Yorozu thread is one tap and asks nothing else, exactly as `+` always was. The Mac shows
/// this as a popover from the compose button; the phone as a sheet. Both call `onStart` with a
/// draft's worth of answer and close themselves.
public struct NewThreadPicker: View {
    private let projects: [ProjectFolder]
    private let onStart: (ThreadAgent, String?) -> Void

    @State private var agent: ThreadAgent? = NewThreadShowcase.agent
    @Environment(\.dismiss) private var dismiss

    public init(projects: [ProjectFolder], onStart: @escaping (ThreadAgent, String?) -> Void) {
        self.projects = projects
        self.onStart = onStart
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let agent, agent.needsFolder {
                    folders(for: agent)
                } else {
                    agents
                }
            }
            .navigationTitle(agent?.needsFolder == true ? "Folder" : "New thread")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if agent?.needsFolder == true {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { agent = nil }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 300, minHeight: 320)
        #endif
    }

    private var agents: some View {
        List {
            Section {
                ForEach(ThreadAgent.allCases) { candidate in
                    Button {
                        if candidate.needsFolder { agent = candidate } else { start(candidate, nil) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.label)
                                Text(describe(candidate))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: candidate.symbol ?? "bubble.left.and.bubble.right")
                        }
                    }
                    .accessibilityHint(candidate.needsFolder ? "Then choose a folder" : "")
                }
            } header: {
                Text("Who answers")
            }
        }
        #if os(macOS)
            .listStyle(.inset)
        #endif
    }

    private func folders(for agent: ThreadAgent) -> some View {
        let recents = projects.filter { $0.lastUsed != nil }
        let rest = projects.filter { $0.lastUsed == nil }
        return List {
            if projects.isEmpty {
                ContentUnavailableView(
                    "No project folders",
                    systemImage: "folder",
                    description: Text("Put a project under ~/Projects on the Mac and it will be listed here.")
                )
            }
            if !recents.isEmpty {
                Section("Recent") { rows(recents, agent: agent) }
            }
            if !rest.isEmpty {
                Section(recents.isEmpty ? "Folders" : "Other folders") { rows(rest, agent: agent) }
            }
        }
        #if os(macOS)
            .listStyle(.inset)
        #endif
    }

    private func rows(_ folders: [ProjectFolder], agent: ThreadAgent) -> some View {
        ForEach(folders) { folder in
            Button { start(agent, folder.path) } label: {
                Label(folder.name, systemImage: "folder")
            }
            .accessibilityLabel("\(folder.name), \(agent.label)")
        }
    }

    private func start(_ agent: ThreadAgent, _ cwd: String?) {
        onStart(agent, cwd)
        dismiss()
    }

    private func describe(_ agent: ThreadAgent) -> String {
        switch agent {
        case .yorozu: String(localized: "Your assistant, with its own tools")
        case .claudeCode: String(localized: "A coding session in one of your projects")
        case .codex: String(localized: "A Codex session in one of your projects")
        }
    }
}
