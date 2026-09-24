import AppKit
import SwiftUI
import YorozuShared

/// The chat window: threads on the left, the chat on the right, and everything that is not
/// chat behind the gear. The detail half has its own `NavigationStack`, which is what the
/// subagent drill-down and the trace pages push onto.
///
/// A real window rather than the menu bar popover this used to be. A `MenuBarExtra` window has
/// no toolbar to put the thread's own controls in, cannot be resized, closes itself the moment
/// a share picker or a reader sheet takes focus, and gives the app no menu bar to hang ⌘N, ⌘F
/// or Stop off — so on the Mac half of the chat's features were simply unreachable. See
/// ``YorozuMacApp``, where the menu bar item is now the way to this window rather than the
/// place the chat lives.
struct ChatWindowView: View {
    @State private var session = MacChatSession.shared
    var body: some View {
        if session.role == .client { ClientChatWindowView(session: session) }
        else { LocalChatWindowView() }
    }
}

private struct ClientChatWindowView: View {
    let session: MacChatSession
    @State private var selection: HostThreadID?
    @State private var searchedThread: HostThreadID?
    @State private var searchRequest: ThreadSearchRequest?
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openSettings) private var openSettings

    private var hosts: MultiHostModel { session.hosts }

    var body: some View {
        NavigationSplitView {
            MultiHostThreadSidebar(session: hosts, selection: $selection) { id, request in
                searchedThread = id
                searchRequest = request
            }
            .navigationSplitViewColumnWidth(min: LayoutMetrics.sidebarMinWidth,
                ideal: LayoutMetrics.sidebarIdealWidth, max: LayoutMetrics.sidebarMaxWidth)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.plain)
                    Spacer()
                    Text(connectionLabel)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(12)
                .background(YorozuPalette.paper)
            }
        } detail: {
            NavigationStack {
                if let selection, let item = hosts.thread(for: selection), let model = hosts.model(for: selection) {
                    ChatView(model: model, thread: item.thread,
                        offlineNotice: hosts.hasMultipleHosts
                            ? "\(item.hostLabel) is offline. Messages will send when it reconnects."
                            : "Connection unavailable. Messages will send when your host Mac reconnects.")
                        .environment(\.threadSearchRequest, searchedThread == selection ? searchRequest : nil)
                        .id(selection)
                } else {
                    ContentUnavailableView("No thread", systemImage: "bubble.left.and.bubble.right",
                        description: Text(hosts.sessions.isEmpty ? "Add a host in Settings to start chatting." : "Choose a thread or start a new one."))
                }
            }
            .id(selection?.hostID)
        }
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
        .background(YorozuPalette.canvas)
        .safeAreaInset(edge: .top) {
            UpdateStatusView(status: Updates.pending.status) { Updates.pending.postpone() }
        }
        .yorozuTint()
        .onChange(of: selection, initial: true) { old, new in
            if let old, old != new {
                hosts.model(for: old)?.discardDraft(old.threadID)
                hosts.model(for: old)?.openThread = nil
            }
            if let new { hosts.lastUsedHostID = new.hostID }
            updateReading()
        }
        .onChange(of: hosts.lastUsedHostID) { _, _ in session.rememberLastHost() }
        .onChange(of: controlActiveState, initial: true) { _, _ in updateReading() }
        .onChange(of: hosts.sessions.map(\.id)) { _, _ in
            if let selection, hosts.session(for: selection.hostID) == nil { self.selection = nil }
            if selection == nil { open() }
            updateReading()
        }
        .onAppear { open() }
        .onDisappear {
            for host in hosts.sessions { host.model.foreground = false }
        }
        .background(WindowNumberReporter())
    }

    private var connectionLabel: String {
        guard !hosts.hasMultipleHosts else { return hosts.connectionSummary }
        guard let host = hosts.sessions.first else { return "Not connected" }
        if case .updateRequired = host.model.compatibility { return "Update required" }
        return ClientConnectionStatus(state: host.model.state, ownerOnline: host.model.ownerOnline,
            failure: session.hostFailures[host.id] ?? host.model.failure).label
    }

    private func updateReading() {
        guard selection != nil else {
            for host in hosts.sessions { host.model.foreground = false }
            return
        }
        for host in hosts.sessions {
            let selected = selection?.hostID == host.id
            host.model.foreground = selected && controlActiveState == .key
            host.model.openThread = selected ? selection?.threadID : nil
        }
    }

    private func open() {
        guard selection == nil else { return }
        if let id = hosts.preferredHostID, let model = hosts.session(for: id)?.model,
           let saved = model.openThread, model.threads.contains(where: { $0.id == saved }) {
            selection = HostThreadID(hostID: id, threadID: saved)
        } else if let newest = hosts.threads.first(where: { !$0.thread.archived }), threadToOpen([newest.thread]) != nil {
            selection = newest.id
        } else { selection = hosts.newDraft() }
        updateReading()
    }
}

private struct LocalChatWindowView: View {
    @State private var session = MacChatSession.shared
    @State private var selection: String?
    @State private var searchRequest: ThreadSearchRequest?
    /// `.key` is this window being the key window of the active app, which is exactly the Mac's
    /// half of "somebody is looking at this": `.active` is a window in the active app that is
    /// not key, and `.inactive` is the whole app sitting behind something else.
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openSettings) private var openSettings

    private var model: ChatModel { session.model }

    /// Falls back to the first thread, so archiving the selected one leaves a chat on screen.
    private var thread: ThreadSummary? {
        model.threads.first { $0.id == selection } ?? visibleThreads(model.threads).first
    }

    /// Opening the window is this app's "came back to the foreground": carry on with the most
    /// recent thread while it is still warm, and start a fresh draft once it is not. The first
    /// open of a launch happens before the sidecar has answered, so it waits for the list.
    private func open() {
        selection = model.openThread.flatMap { id in model.threads.contains { $0.id == id } ? id : nil }
            ?? threadToOpen(model.threads) ?? model.draft?.id ?? model.newDraft().id
    }

    var body: some View {
        NavigationSplitView {
            ThreadSidebar(
                threads: model.threads,
                workingThreads: model.generating,
                selection: $selection,
                projects: model.projects,
                projectListStatus: model.projectListStatus,
                onRefreshProjects: { await model.refreshProjects() },
                onCreate: { agent, cwd in selection = model.newDraft(agent: agent, cwd: cwd).id },
                onRename: { model.rename($0, to: $1) },
                onArchive: model.setArchived,
                onPin: model.setPinned,
                onRead: { thread, read in
                    read ? model.markRead(thread.id) : model.markUnread(thread)
                },
                onReadAll: model.markAllRead,
                // Search reaches into this Mac's own thread logs, which is every word of them.
                messageText: { id in
                    (model.events[id] ?? []).compactMap {
                        if case .message(let data) = $0.payload { return data.text }
                        return nil
                    }
                    .joined(separator: "\n\n")
                },
                exportMarkdown: model.markdown(of:),
                onSearchSelect: { searchRequest = $0 }
            )
            .navigationSplitViewColumnWidth(
                min: LayoutMetrics.sidebarMinWidth,
                ideal: LayoutMetrics.sidebarIdealWidth,
                max: LayoutMetrics.sidebarMaxWidth
            )
            .safeAreaInset(edge: .bottom) { gear }
        } detail: {
            NavigationStack {
                if let thread {
                    ChatView(
                        model: model,
                        thread: thread,
                        offlineNotice: "Runtime not reachable — see Settings for its state."
                    )
                    .environment(\.threadSearchRequest, searchRequest)
                } else {
                    ContentUnavailableView("No thread", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        // A floor rather than a fixed size: the window is resizable now, and the chat has to
        // stay legible at the narrowest a window is worth having.
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
        .background(YorozuPalette.canvas)
        .safeAreaInset(edge: .top) {
            if session.role != .host {
                UpdateStatusView(status: Updates.pending.status) { Updates.pending.postpone() }
            }
        }
        .yorozuTint()
        // Selecting something else discards empty drafts, keeps input, and
        // tells the model which thread is being read — a reply landing in the open thread is
        // read on arrival, and one landing anywhere else raises a dot in the sidebar.
        .onChange(of: selection, initial: true) { old, new in
            if let old, old != new { model.discardDraft(old) }
            if new != nil || old != nil { model.openThread = new }
        }
        // A window sitting on a thread behind everything else is nobody reading it, so the
        // thread is only reported read while this window is the key one of the active app.
        .onChange(of: controlActiveState, initial: true) { _, state in
            model.foreground = state == .key
        }
        .onAppear { if model.listed { open() } }
        .onChange(of: model.listed) { _, listed in if listed { open() } }
        // Screenshot harness only: prints the window number `screencapture -l` wants. Inert
        // unless a showcase argument was passed — see ``Showcase``.
        .background(WindowNumberReporter())
    }

    /// Pairing, permissions and the wizard all moved into the Settings scene when
    /// the window became the chat; this is the way back to them, plus the sidecar's state.
    private var gear: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                CheckForUpdatesButton()
                Divider()
                Button("Quit Yorozu") { NSApp.terminate(nil) }
            } label: {
                HStack(spacing: 6) {
                    YorozuMark(dimension: 15)
                    Text("Yorozu")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
            Label {
                Text(connectionLabel)
            } icon: {
                Image(systemName: model.state == .paired ? "circle.fill" : "circle.dotted")
                    .font(.system(size: 7))
                    .foregroundStyle(model.state == .paired ? YorozuPalette.sage : Color.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("Relay state reported by the runtime")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(YorozuPalette.paper)
    }

    private var connectionLabel: String {
        switch model.state {
        case .paired: "Connected"
        case .connecting, .joined: "Connecting"
        case .closed: "Offline"
        }
    }
}

/// Everything that is not chat. These used to be stacked in the menu bar window itself; the
/// window is the chat now, so they live in the standard Settings scene where ⌘, and the gear
/// menu both find them.
struct SettingsView: View {
    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general, hosts, devices, permissions

        var id: Self { self }
        var presentation: (title: String, symbol: String) {
            switch self {
            case .general: ("General", "gearshape")
            case .hosts: ("Hosts", "desktopcomputer")
            case .devices: ("Devices", "iphone.and.arrow.forward")
            case .permissions: ("Permissions", "lock.shield")
            }
        }
    }

    @ObservedObject var sidecar: Sidecar
    @State private var session = MacChatSession.shared
    @State private var selection: SettingsSection? = .general

    private var sections: [SettingsSection] {
        session.role == .host ? [.general, .devices, .permissions] : [.general, .hosts]
    }

    private func presentation(for section: SettingsSection) -> (title: String, symbol: String) {
        if section == .hosts, !session.hosts.hasMultipleHosts { return ("Connection", "link") }
        return section.presentation
    }

    var body: some View {
        NavigationSplitView {
            List(sections, selection: $selection) { section in
                Label(presentation(for: section).title, systemImage: presentation(for: section).symbol)
                    .tag(section)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            pane { selectedView }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 580)
        .onChange(of: session.role) { _, role in
            if role != .host { selection = .general }
        }
    }

    private func pane(@ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(presentation(for: selection ?? .general).title)
                    .font(.title2.weight(.semibold))
                content()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(YorozuPalette.canvas)
    }

    @ViewBuilder private var selectedView: some View {
        switch selection ?? .general {
        case .general: GeneralView()
        case .hosts: HostsView()
        case .devices: DevicesView(sidecar: sidecar)
        case .permissions: PermissionsView(showsTitle: false)
        }
    }
}
