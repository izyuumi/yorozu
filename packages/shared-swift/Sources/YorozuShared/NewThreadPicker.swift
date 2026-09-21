import SwiftUI

/// Test harness only: which folder a coding-agent picker opens on, so a screenshot can show
/// the second step without a tap.
@MainActor public enum NewThreadShowcase {
    public static var agent: ThreadAgent?
}

/// Who should answer a new thread, and — for a coding agent — where. Two steps at most, and a
/// recent folder is two taps from the `+`: the agent, then the folder at the top of its list.
///
/// A Yorozu thread is one tap and asks nothing else. The coding agents are pushed onto the
/// sheet's own stack, so the folder step has the system back button and edge swipe. Both apps
/// show this as a sheet from their new-thread buttons and keyboard shortcuts. Both call
/// `onStart` with a draft's worth of answer and close themselves.
public struct NewThreadPicker: View {
    private let projects: [ProjectFolder]
    private let onStart: (ThreadAgent, String?) -> Void

    @State private var path: [ThreadAgent] = NewThreadShowcase.agent.map { [$0] } ?? []
    @Environment(\.dismiss) private var dismiss

    public init(projects: [ProjectFolder], onStart: @escaping (ThreadAgent, String?) -> Void) {
        self.projects = projects
        self.onStart = onStart
    }

    /// The runtime that answers anywhere, and the ones that need a folder on the Mac first.
    static let assistants = ThreadAgent.allCases.filter { !$0.needsFolder }
    static let codingAgents = ThreadAgent.allCases.filter(\.needsFolder)

    /// Folders used before, most recent first, then the rest in the order the Mac sent them.
    static func sections(_ projects: [ProjectFolder]) -> (recent: [ProjectFolder], other: [ProjectFolder]) {
        (
            projects.filter { $0.lastUsed != nil }.sorted { $0.lastUsed! > $1.lastUsed! },
            projects.filter { $0.lastUsed == nil }
        )
    }

    /// One line under each runtime's name: what it is, and what choosing it costs.
    static func summary(_ agent: ThreadAgent) -> String {
        switch agent {
        case .yorozu: String(localized: "Your assistant on OpenClaw, with its own tools. Starts right away.")
        case .claudeCode: String(localized: "Anthropic’s coding agent, working in a project on your Mac.")
        case .codex: String(localized: "OpenAI’s coding agent, working in a project on your Mac.")
        }
    }

    public var body: some View {
        NavigationStack(path: $path) {
            runtimes
                .navigationTitle("New thread")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .navigationDestination(for: ThreadAgent.self) { folders(for: $0) }
        }
        .yorozuTint()
        #if os(macOS)
            .frame(minWidth: 380, minHeight: 440)
        #endif
    }

    private var runtimes: some View {
        List {
            Section {
                ForEach(Self.assistants) { agent in
                    Button { start(agent, nil) } label: { runtime(agent) }
                        .listRowBackground(YorozuPalette.paper)
                        .accessibilityHint("Starts a thread now")
                }
            } header: {
                question("Who should answer?")
            }
            Section {
                ForEach(Self.codingAgents) { agent in
                    NavigationLink(value: agent) { runtime(agent) }
                        .listRowBackground(YorozuPalette.paper)
                        .accessibilityHint("Then choose a project folder")
                }
            } header: {
                Text("Coding agents")
            } footer: {
                Text("Runs on the Mac, in a project folder you choose next.")
            }
        }
        .paperList()
    }

    private func runtime(_ agent: ThreadAgent) -> some View {
        HStack(spacing: 12) {
            Group {
                // Yorozu's own knot rather than the generic chip the thread list uses: this is
                // the one place the runtimes are introduced side by side.
                if agent == .yorozu { YorozuMark(dimension: 22) } else { AgentMarkView(agent) }
            }
            .frame(width: 36, height: 36)
            .background(YorozuPalette.canvas, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(YorozuPalette.rule.opacity(0.72), lineWidth: 0.75)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label)
                    .font(.headline)
                    .foregroundStyle(YorozuPalette.ink)
                Text(Self.summary(agent))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func folders(for agent: ThreadAgent) -> some View {
        let (recent, other) = Self.sections(projects)
        return List {
            if projects.isEmpty {
                ContentUnavailableView(
                    "No project folders",
                    systemImage: "folder",
                    description: Text("Put a project under ~/Projects on the Mac and it will be listed here.")
                )
                .listRowBackground(Color.clear)
            }
            if !recent.isEmpty {
                Section {
                    rows(recent, agent: agent)
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        question("Where should \(agent.label) work?")
                        Text("Recent")
                    }
                }
            }
            if !other.isEmpty {
                Section {
                    rows(other, agent: agent)
                } header: {
                    if recent.isEmpty { question("Where should \(agent.label) work?") } else { Text("Other folders") }
                }
            }
        }
        .paperList()
        .navigationTitle(agent.label)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
            // A sheet on the Mac has no toolbar for the stack's own back button.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { path.removeLast() }
                }
            }
        #endif
    }

    private func rows(_ folders: [ProjectFolder], agent: ThreadAgent) -> some View {
        ForEach(folders) { folder in
            Button { start(agent, folder.path) } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.name).foregroundStyle(YorozuPalette.ink)
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .listRowBackground(YorozuPalette.paper)
            .accessibilityLabel("\(folder.name), \(agent.label)")
        }
    }

    /// The sheet's one editorial moment: the question it asks, in the serif agent replies use.
    private func question(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .fontDesign(.serif)
            .foregroundStyle(YorozuPalette.ink)
            .textCase(nil)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func start(_ agent: ThreadAgent, _ cwd: String?) {
        onStart(agent, cwd)
        dismiss()
    }
}

private extension View {
    /// Paper rows on the warm canvas, as the thread list draws them.
    func paperList() -> some View {
        self
            #if os(macOS)
                .listStyle(.inset)
            #else
                .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(YorozuPalette.canvas)
    }
}
