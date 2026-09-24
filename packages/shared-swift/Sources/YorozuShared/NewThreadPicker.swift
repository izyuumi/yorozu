import SwiftUI

/// Test harness only: which folder a coding-agent picker opens on, so a screenshot can show
/// the second step without a tap.
@MainActor public enum NewThreadShowcase {
    public static var agent: ThreadAgent?
    /// UI tests deliver an incoming reply once the folder step is actually on screen.
    public static var onFoldersAppear: (() -> Void)?
}

/// Who should answer a new thread, and — for a coding agent — where. Two steps at most, and a
/// recent folder is two taps from the `+`: the agent, then the folder at the top of its list.
///
/// A Yorozu thread is one tap and asks nothing else. The coding agents are pushed onto the
/// sheet's own stack, so the folder step has the system back button and edge swipe. Both apps
/// show this as a sheet from their new-thread buttons and keyboard shortcuts. Both call
/// `onStart` with a draft's worth of answer and close themselves.
public struct NewThreadPicker: View {
    private let fallbackProjects: [ProjectFolder]
    private let fallbackStatus: ProjectListStatus
    private let fallbackRefresh: (() async -> Void)?
    private let onStart: (ThreadAgent, String?) -> Void
    private let session: MultiHostModel?
    private let onHostStart: ((HostThreadID) -> Void)?

    @State private var selectedHostID: HostID?

    @State private var path: [ThreadAgent] = NewThreadShowcase.agent.map { [$0] } ?? []
    @Environment(\.dismiss) private var dismiss

    public init(
        projects: [ProjectFolder],
        status: ProjectListStatus = .ready,
        onRefresh: (() async -> Void)? = nil,
        onStart: @escaping (ThreadAgent, String?) -> Void
    ) {
        self.fallbackProjects = projects
        self.fallbackStatus = status
        self.fallbackRefresh = onRefresh
        self.onStart = onStart
        self.session = nil
        self.onHostStart = nil
    }

    /// Host choice stays inside the existing sheet. Each change replaces the project source
    /// and pops any agent's folder step before a draft can be created on another Mac.
    public init(session: MultiHostModel, onStart: @escaping (HostThreadID) -> Void) {
        self.fallbackProjects = []
        self.fallbackStatus = .ready
        self.fallbackRefresh = nil
        self.onStart = { _, _ in }
        self.session = session
        self.onHostStart = onStart
        self._selectedHostID = State(initialValue: session.preferredHostID)
    }

    private var selectedHost: HostSession? {
        selectedHostID.flatMap { session?.session(for: $0) }
    }
    private var canStart: Bool {
        guard session != nil else { return true }
        guard let selectedHost else { return false }
        if case .updateRequired = selectedHost.model.compatibility { return false }
        return true
    }
    private var projects: [ProjectFolder] { selectedHost?.model.projects ?? fallbackProjects }
    private var status: ProjectListStatus { selectedHost?.model.projectListStatus ?? fallbackStatus }
    private var onRefresh: (() async -> Void)? {
        if let model = selectedHost?.model { return { await model.refreshProjects() } }
        return fallbackRefresh
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
        .onChange(of: selectedHostID) { _, _ in path = [] }
        .onChange(of: session?.sessions.map(\.id)) { _, ids in
            if selectedHostID.map({ ids?.contains($0) == true }) != true {
                self.selectedHostID = session?.preferredHostID
            }
        }
        .task(id: "\(selectedHostID ?? ""):\(status == .offline)") {
            guard status != .offline else { return }
            await onRefresh?()
        }
        #if os(macOS)
            .frame(minWidth: 380, minHeight: 440)
        #endif
    }

    private var runtimes: some View {
        List {
            if let session, session.hasMultipleHosts || selectedHost?.model.canDeliver == false {
                Section {
                    if session.hasMultipleHosts {
                        Picker("Host", selection: $selectedHostID) {
                            ForEach(session.sessions) { host in
                                Text(host.label).tag(Optional(host.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityHint("The Mac that will receive this new thread")
                    }
                    if let host = selectedHost {
                        if case .updateRequired = host.model.compatibility {
                            Label("Update required — see Settings", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !host.model.canDeliver {
                            Label("Mac offline — messages will queue", systemImage: "wifi.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(YorozuPalette.paper)
            }
            Section {
                ForEach(Self.assistants) { agent in
                    Button { start(agent, nil) } label: { runtime(agent) }
                        .disabled(!canStart)
                        .listRowBackground(YorozuPalette.paper)
                        .accessibilityHint("Starts a thread now")
                }
            } header: {
                question("Who should answer?")
            }
            Section {
                ForEach(Self.codingAgents) { agent in
                    NavigationLink(value: agent) { runtime(agent) }
                        .disabled(!canStart)
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
                    // Not `.secondary`: inside a Button label it picks up the vermilion tint.
                    .foregroundStyle(YorozuPalette.ink.opacity(0.62))
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
                emptyFolders.listRowBackground(Color.clear)
            } else if status != .ready {
                projectStatus.listRowBackground(Color.clear)
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
            Section {
                if let onRefresh {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Label("Refresh folders", systemImage: "arrow.clockwise")
                    }
                    .disabled(status == .loading || status == .offline)
                }
            } footer: {
                Text("Folders come from the host Mac’s projects directory (~/Projects by default). Add a project folder there, then refresh.")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .paperList()
        .navigationTitle(agent.label)
        .onAppear { NewThreadShowcase.onFoldersAppear?() }
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

    @ViewBuilder private var emptyFolders: some View {
        switch status {
        case .ready:
            ContentUnavailableView("No project folders", systemImage: "folder",
                description: Text("Add a project folder on the host Mac to get started."))
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading project folders…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        case .offline:
            ContentUnavailableView("Host Mac unavailable", systemImage: "wifi.slash",
                description: Text("Connect to your host Mac to load its project folders."))
        case .failed:
            ContentUnavailableView("Couldn’t load project folders", systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                description: Text("Check that Yorozu is running on the host Mac, then refresh."))
        }
    }

    @ViewBuilder private var projectStatus: some View {
        switch status {
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading project folders…")
            }
        case .offline:
            Label("Host Mac unavailable. Showing previously loaded folders.", systemImage: "wifi.slash")
        case .failed:
            Label("Couldn’t refresh. Showing previously loaded folders.", systemImage: "exclamationmark.circle")
        case .ready:
            EmptyView()
        }
    }

    private func rows(_ folders: [ProjectFolder], agent: ThreadAgent) -> some View {
        ForEach(folders) { folder in
            Button { start(agent, folder.path) } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.name)
                            .foregroundStyle(YorozuPalette.ink)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        // Monospaced so a path reads as a path, and wrapping so a long one is
                        // shown whole rather than losing its middle to an ellipsis.
                        Text(folder.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(YorozuPalette.ink.opacity(0.62))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "folder").foregroundStyle(YorozuPalette.ink.opacity(0.62))
                }
                .frame(maxWidth: .infinity, minHeight: controlTarget, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            // Native macOS button bezels constrain labels to one line, even inside a List.
            // The full-width list row is the button, so paths can use their required height.
            .buttonStyle(.plain)
            .listRowBackground(YorozuPalette.paper)
            .accessibilityLabel("\(folder.name), \(agent.label)")
            .accessibilityValue(folder.path)
            .accessibilityHint("Starts a thread in this folder on the host Mac")
            #if os(macOS)
                .help(folder.path)
            #endif
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
        if let session {
            guard canStart, !agent.needsFolder || projects.contains(where: { $0.path == cwd }),
                let selectedHostID, selectedHost != nil,
                let id = session.newDraft(on: selectedHostID, agent: agent, cwd: cwd)
            else { return }
            onHostStart?(id)
        } else {
            onStart(agent, cwd)
        }
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
