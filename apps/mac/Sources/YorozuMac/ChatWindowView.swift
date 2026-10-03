import AppKit
import SwiftUI
import YorozuKeepalive
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
    @State private var showingHistory = false
    @State private var router = ChatWindowRouter.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    var body: some View {
        Group {
            if SecretaryUI.enabled && !showingHistory {
                NavigationStack {
                    SecretaryChatView(model: session.model,
                        hostLabel: session.role == .client ? session.hosts.sessions.first { $0.model === session.model }?.label : nil,
                        onHistory: { showingHistory = true })
                        .id(ObjectIdentifier(session.model))
                }
                .onChange(of: controlActiveState, initial: true) { _, state in
                    session.model.foreground = state == .key
                }
                .onDisappear { session.model.foreground = false }
            } else if session.role == .client { ClientChatWindowView(session: session) }
            else { LocalChatWindowView() }
        }
        .toolbar {
            if SecretaryUI.enabled {
                if showingHistory {
                    ToolbarItem(placement: .navigation) {
                        Button("Yorozu", systemImage: "bubble.left.and.bubble.right") { showingHistory = false }
                            .accessibilityIdentifier("secretary-return")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") { openWindow(id: YorozuMacApp.settingsWindow) }
                }
            }
        }
        .onChange(of: router.threadID, initial: true) { _, id in
            if id != nil { showingHistory = true }
        }
        .modifier(SecretaryLocale())
        // Text with no font of its own, the composer's included, follows ⌘+ and ⌘− too.
        .font(.scaled(.body))
        .overlay(alignment: .top) { ThreadNotificationToast() }
    }
}

/// One conversation in the host's menu-bar mode. The existing ChatView owns transcript,
/// composer, attachments, approvals and their persisted per-thread state.
struct QuickChatView: View {
    // Window owns its initial geometry; users can resize it after opening.
    static let initialWidth: CGFloat = 560
    static let initialHeight: CGFloat = 660

    @State private var session = MacChatSession.shared
    @State private var router = QuickChatRouter.shared
    @State private var selection: String?
    @AppStorage("quickChatThreadID") private var lastThreadID = ""
    @Environment(\.controlActiveState) private var controlActiveState

    private var model: ChatModel { session.model }
    private var thread: ThreadSummary? { model.threads.first { $0.id == selection } }
    private var target: QuickChatTarget? { router.target?.threadID == selection ? router.target : nil }

    var body: some View {
        if SecretaryUI.enabled && router.target == nil { ChatWindowView() }
        else { legacyChat }
    }

    private var legacyChat: some View {
        NavigationStack {
            if let thread {
                ChatView(model: model, thread: thread,
                    resumeRequest: target?.id,
                    notificationClass: target?.kind?.rawValue,
                    notificationEventRef: target?.eventID.map(YorozuCrypto.threadRef),
                    showsUpdateStatus: false,
                    focusComposerOnAppear: target == nil,
                    onCreate: { agent, cwd in
                        let id = model.newDraft(agent: agent, cwd: cwd).id
                        selection = id
                        return id
                    })
                    .id(thread.id)
            } else {
                ContentUnavailableView("No chat yet", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start a chat from the menu bar."))
            }
        }
        .toolbar {
            QuickChatToolbar(threads: Array(visibleThreads(model.threads).prefix(8)),
                onNew: newChat, onSelect: { router.target = nil; selection = $0 })
        }
        .focusedSceneValue(\.threadCommands, ThreadCommands(newThread: newChat))
        .font(.scaled(.body))
        .background(YorozuPalette.canvas)
        .yorozuTint()
        .overlay(alignment: .top) { ThreadNotificationToast() }
        .onAppear { open() }
        .onChange(of: selection, initial: true) { old, new in
            if let old, old != new { model.discardDraft(old) }
            model.openThread = new
            if let new { lastThreadID = new }
        }
        .onChange(of: lastThreadID) { _, id in
            if model.threads.contains(where: { $0.id == id }) { selection = id }
        }
        .onChange(of: router.target?.id, initial: true) { _, _ in followTarget() }
        .onChange(of: model.threads.map(\.id)) { _, _ in followTarget() }
        .onChange(of: model.listed) { _, listed in if listed && selection == nil { open() } }
        .onChange(of: controlActiveState, initial: true) { _, state in
            model.foreground = state == .key
        }
        .onDisappear {
            model.foreground = false
            router.target = nil
            do { try model.saveForRestart() }
            catch { Log.write("quick chat: could not save draft on close — \(error.localizedDescription)") }
        }
    }

    private func open() {
        guard selection == nil else { return }
        if router.target != nil { followTarget(); return }
        guard model.listed || !model.threads.isEmpty else { return }
        selection = model.threads.first { $0.id == lastThreadID && !$0.archived }?.id
            ?? visibleThreads(model.threads).first?.id
            ?? model.newDraft().id
    }

    private func newChat() {
        router.target = nil
        selection = model.newDraft().id
    }

    private func followTarget() {
        if let id = router.target?.threadID, model.threads.contains(where: { $0.id == id }) {
            selection = id
        }
    }
}

private struct QuickChatToolbar: ToolbarContent {
    let threads: [ThreadSummary]
    let onNew: () -> Void
    let onSelect: (String) -> Void
    @FocusedValue(\.chatCommands) private var chat

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Find in Thread", systemImage: "magnifyingglass") { chat?.find() }
                .disabled(chat == nil)
            Button("New Chat", systemImage: "square.and.pencil", action: onNew)
            Menu {
                ForEach(threads) { item in
                    Button(item.displayTitle) { onSelect(item.id) }
                }
            } label: {
                Label("Recent Chats", systemImage: "ellipsis.circle")
            }
            .disabled(threads.isEmpty)
        }
    }
}

private struct ClientChatWindowView: View {
    let session: MacChatSession
    @State private var router = ChatWindowRouter.shared
    @State private var selection: HostThreadID?
    @State private var searchedThread: HostThreadID?
    @State private var searchRequest: ThreadSearchRequest?
    @Environment(\.controlActiveState) private var controlActiveState

    private var hosts: MultiHostModel { session.hosts }

    var body: some View {
        NavigationSplitView {
            MultiHostThreadSidebar(session: hosts, selection: $selection) { id, request in
                searchedThread = id
                searchRequest = request
            }
            .navigationSplitViewColumnWidth(min: LayoutMetrics.sidebarMinWidth,
                ideal: LayoutMetrics.sidebarIdealWidth, max: LayoutMetrics.sidebarMaxWidth)
            .safeAreaInset(edge: .bottom) { SidebarFooter(connection: connectionLabel) }
        } detail: {
            NavigationStack {
                if let selection, let item = hosts.thread(for: selection), let model = hosts.model(for: selection) {
                    ChatView(model: model, thread: item.thread,
                        aggregateToast: hosts.connectionToastNotice?.notice.state,
                        aggregateToastID: hosts.connectionToastNotice?.notice.id,
                        aggregateToastAnnouncementRevision: hosts.connectionToastNotice?.notice.announcementRevision,
                        aggregateToastLabel: hosts.connectionToastLabel,
                        hosts: hosts,
                        hostID: selection.hostID,
                        onDraftMove: { self.selection = $0 },
                        onNewThread: { if let id = hosts.newDraft() { self.selection = id } },
                        onCreate: { agent, cwd in
                            guard let draft = hosts.newDraft(on: selection.hostID, agent: agent, cwd: cwd) else { return nil }
                            self.selection = draft
                            return draft.threadID
                        })
                        .environment(\.threadSearchRequest, searchedThread == selection ? searchRequest : nil)
                        .id(selection)
                } else {
                    ContentUnavailableView("No thread", systemImage: "bubble.left.and.bubble.right",
                        description: Text(hosts.sessions.isEmpty ? String(localized: "Add a host in Settings to start chatting.") : String(localized: "Choose a thread or start a new one.")))
                }
            }
            .id(selection?.hostID)
            .background(YorozuPalette.canvas)
            .safeAreaInset(edge: .top) {
                UpdateStatusView(status: Updates.pending.status, postpone: { Updates.pending.postpone() },
                                 installNow: { Updates.pending.installNow() })
            }
        }
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
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
        .onChange(of: router.threadID, initial: true) { _, id in
            guard let id else { return }
            defer { router.threadID = nil; router.hostID = nil }
            guard let hostID = router.hostID else { return }
            let thread = HostThreadID(hostID: hostID, threadID: id)
            guard hosts.thread(for: thread) != nil else { return }
            selection = thread
        }
        .onAppear { open() }
        .onDisappear {
            for host in hosts.sessions { host.model.foreground = false }
        }
        .background(WindowNumberReporter())
    }

    private var connectionLabel: String {
        guard !hosts.hasMultipleHosts else { return hosts.connectionSummary }
        guard let host = hosts.sessions.first else { return String(localized: "Not connected") }
        if case .updateRequired = host.model.compatibility { return String(localized: "Update required") }
        return ClientConnectionStatus(host.model, failure: session.hostFailures[host.id] ?? host.model.failure).label
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
    @State private var router = ChatWindowRouter.shared
    @State private var selection: String?
    @State private var searchRequest: ThreadSearchRequest?
    /// `.key` is this window being the key window of the active app, which is exactly the Mac's
    /// half of "somebody is looking at this": `.active` is a window in the active app that is
    /// not key, and `.inactive` is the whole app sitting behind something else.
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow

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
                agentLabel: { model.agentLabel($0.agent ?? .yorozu) },
                selection: $selection,
                projects: model.projects,
                agents: model.availableAgents,
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
                remoteMatches: model.remoteSearch,
                remoteQuery: model.searchQuery,
                searchScope: model.searchScope,
                onSearchQueryChange: model.searchHost,
                exportMarkdown: model.markdown(of:),
                onSearchSelect: { searchRequest = $0 }
            )
            .navigationSplitViewColumnWidth(
                min: LayoutMetrics.sidebarMinWidth,
                ideal: LayoutMetrics.sidebarIdealWidth,
                max: LayoutMetrics.sidebarMaxWidth
            )
            .safeAreaInset(edge: .bottom) { SidebarFooter(connection: connectionLabel) }
        } detail: {
            NavigationStack {
                if let thread {
                    ChatView(model: model, thread: thread,
                        onCreate: { agent, cwd in
                            let id = model.newDraft(agent: agent, cwd: cwd).id
                            selection = id
                            return id
                        })
                    .environment(\.threadSearchRequest, searchRequest)
                    // One view per thread, as on a client: switching threads starts the chat's
                    // own state — scroll, search, focus — afresh rather than carrying it over.
                    .id(thread.id)
                } else {
                    ContentUnavailableView("No thread", systemImage: "bubble.left.and.bubble.right",
                        description: Text(String(localized: "Choose a thread or start a new one.")))
                }
            }
            // The canvas and update banner belong to the chat; the sidebar keeps its own material.
            .background(YorozuPalette.canvas)
            .safeAreaInset(edge: .top) {
                if session.role != .host {
                    UpdateStatusView(status: Updates.pending.status, postpone: { Updates.pending.postpone() },
                                     installNow: { Updates.pending.installNow() })
                }
            }
        }
        // A floor rather than a fixed size: the window is resizable now, and the chat has to
        // stay legible at the narrowest a window is worth having.
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
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
        .onAppear {
            if model.listed { open() }
            // Screenshot harness only — see ``Showcase``.
            if launchArgument("yorozuWindow") == "settings" { openWindow(id: YorozuMacApp.settingsWindow) }
        }
        .onChange(of: router.threadID, initial: true) { _, id in
            guard let id else { return }
            defer { router.threadID = nil; router.hostID = nil }
            guard model.threads.contains(where: { $0.id == id }) else { return }
            model.openThread = id
            selection = id
        }
        .onChange(of: model.listed) { _, listed in if listed { open() } }
        .onDisappear { model.foreground = false }
        // Screenshot harness only: prints the window number `screencapture -l` wants. Inert
        // unless a showcase argument was passed — see ``Showcase``.
        .background(WindowNumberReporter())
    }

    /// A sidecar restart shorter than the grace keeps saying Connected.
    private var connectionLabel: String {
        if model.link.state == .connected { return String(localized: "Connected") }
        return model.state == .closed ? String(localized: "Offline") : String(localized: "Connecting")
    }
}

/// The foot of the sidebar, the same on a host and a client: the way to Settings — where
/// pairing, permissions and the wizard live — and how this window's chat is connected.
/// Updates and Quit are in the menu bar item and the app menu, as on every Mac.
private struct SidebarFooter: View {
    let connection: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Button { openWindow(id: YorozuMacApp.settingsWindow) } label: { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.plain)
            Spacer()
            Text(connection)
                .foregroundStyle(.secondary)
        }
        .font(.scaled(.caption))
        .padding(12)
        .background(YorozuPalette.paper)
    }
}

/// Everything that is not chat. These used to be stacked in the menu bar window itself; the
/// window is the chat now, so they live in the Settings window where ⌘, and the
/// sidebar's Settings button both find them.
///
/// A sidebar of panes under one toolbar, as System Settings is. The toolbar is what makes
/// the sidebar run the full height of the window: without an item in it the window keeps a
/// plain title bar across the top.
@MainActor @Observable
final class SettingsPaneRouter {
    static let shared = SettingsPaneRouter()
    var selection: String?
    /// Opens the Settings window. Set by ``YorozuMacApp``, whose `openWindow` is the one that
    /// works from windows outside the scene graph, such as setup.
    static var openWindow: (() -> Void)?

    /// Shows `pane`, opening Settings or bringing it forward.
    func open(_ pane: String) {
        selection = pane
        NSApp.activate(ignoringOtherApps: true)
        Self.openWindow?()
    }
}

/// The thread Settings asked the chat window to show.
@MainActor @Observable
final class ChatWindowRouter {
    static let shared = ChatWindowRouter()
    var threadID: String?
    var hostID: HostID?
}

struct SettingsView: View {
    @ObservedObject var sidecar: Sidecar
    @State private var session = MacChatSession.shared
    @State private var route = SettingsPaneRouter.shared
    @AppStorage(HostWindowMode.key) private var backgroundOnlyHost = false
    // The pane, or the one a screenshot asked for — see ``Showcase``.
    @State private var selection: String? = launchArgument("yorozuSettingsPane") ?? "general"

    /// The panes walked through, for Back and Forward, and where in them this is.
    @State private var visited: [String] = []
    @State private var position = 0

    private typealias Pane = (id: String, title: LocalizedStringKey, icon: String)

    private var panes: [Pane] {
        var panes: [Pane] = [("general", "General", "gearshape")]
        if session.role == .host {
            panes.append(("devices", "Devices", "iphone.and.arrow.forward"))
            panes.append(("permissions", "Permissions", "lock.shield"))
        } else if session.hosts.hasMultipleHosts {
            panes.append(("hosts", "Hosts", "desktopcomputer"))
        } else {
            panes.append(("hosts", "Connection", "link"))
        }
        panes.append(("notifications", "Notifications", "bell"))
        return panes
    }

    var body: some View {
        let pane = panes.first { $0.id == selection } ?? panes[0]
        NavigationSplitView {
            List(panes, id: \.id, selection: $selection) { Label($0.title, systemImage: $0.icon) }
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane.id {
                case "devices": DevicesView(sidecar: sidecar)
                case "permissions": PermissionsView()
                case "notifications": MacNotificationsView()
                case "hosts": HostsView()
                default: GeneralView(sidecar: sidecar)
                }
            }
            .navigationTitle(pane.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") { go(-1) }
                        .disabled(position == 0)
                    Button("Forward", systemImage: "chevron.right") { go(1) }
                        .disabled(position >= visited.count - 1)
                }
            }
        }
        // Taken once, so asking for the same pane again later still counts as a change.
        .onAppear { if let pane = route.selection { selection = pane; route.selection = nil } }
        // Asked for while already open: the window is only brought forward, so it will not appear again.
        .onChange(of: route.selection) { _, pane in if let pane { selection = pane; route.selection = nil } }
        .onChange(of: route.selection) { _, pane in if let pane { selection = pane } }
        .onChange(of: session.role) { _, _ in selection = "general" }
        .onChange(of: backgroundOnlyHost) { _, active in if !active { selection = "general" } }
        .onChange(of: selection, initial: true) { _, pane in
            // Back and Forward land here too, on the pane already at `position`.
            guard let pane, visited.isEmpty || visited[position] != pane else { return }
            visited = visited.prefix(position + 1) + [pane]
            position = visited.count - 1
        }
    }

    private func go(_ step: Int) {
        position += step
        selection = visited[position]
    }
}
