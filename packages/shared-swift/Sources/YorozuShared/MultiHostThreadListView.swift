import SwiftUI

extension HostThreadID {
    /// Only the existing list widgets use this string. The host and raw ID remain separate
    /// everywhere else; the byte-length prefix prevents even delimiter-containing IDs colliding.
    var listID: String { "\(hostID.utf8.count):\(hostID)\(threadID)" }
}

/// Reuses the mature single-host list's grouping and controls without ever handing a synthetic
/// ID to a chat model. Every callback resolves back to its authenticated host first.
@MainActor
struct HostThreadListAdapter {
    let session: MultiHostModel

    let threads: [ThreadSummary]
    let workingThreads: Set<String>
    private let records: [String: HostThread]

    init(session: MultiHostModel) {
        self.session = session
        let items = session.threads
        self.records = Dictionary(uniqueKeysWithValues: items.map { ($0.id.listID, $0) })
        self.threads = items.map { item in
            var thread = item.thread
            thread.id = item.id.listID
            return thread
        }
        self.workingThreads = Set(items.compactMap { item in
            session.model(for: item.id)?.generating.contains(item.thread.id) == true
                ? item.id.listID : nil
        })
    }

    func hostLabel(_ listID: String) -> String? {
        session.hasMultipleHosts ? records[listID]?.hostLabel : nil
    }

    func resolve(_ listID: String) -> HostThread? {
        records[listID].flatMap { session.thread(for: $0.id) }
    }

    func perform(_ thread: ThreadSummary, _ action: (ChatModel, ThreadSummary) -> Void) {
        guard let item = resolve(thread.id), let model = session.model(for: item.id) else { return }
        action(model, item.thread)
    }

    func messageText(_ listID: String) -> String {
        guard let id = records[listID]?.id else { return "" }
        return session.messageText(for: id)
    }

    var remoteMatches: [String: ThreadSearchMatch] {
        Dictionary(uniqueKeysWithValues: records.compactMap { listID, item in
            guard let match = session.model(for: item.id)?.remoteSearch[item.id.threadID] else { return nil }
            return (listID, ThreadSearchMatch(threadId: listID, eventId: match.eventId, excerpt: match.excerpt))
        })
    }

    var remoteQuery: String? {
        let queries = Set(session.sessions.map { $0.model.searchQuery })
        return queries.count == 1 ? queries.first : nil
    }

    func markdown(_ thread: ThreadSummary) -> String {
        guard let item = resolve(thread.id), let model = session.model(for: item.id) else { return "" }
        return model.markdown(of: item.thread)
    }

    func searchRequest(_ request: ThreadSearchRequest?) -> (HostThreadID, ThreadSearchRequest)? {
        guard let request, let item = resolve(request.threadId) else { return nil }
        return (item.id, ThreadSearchRequest(threadId: item.thread.id, query: request.query,
                                              eventId: request.eventId, id: request.id))
    }
}

/// Combined client list. The reusable list sees qualified presentation IDs; navigation and
/// destinations expose the typed identity and the owning model's original thread.
public struct MultiHostThreadListView<Destination: View>: View {
    private let session: MultiHostModel
    @Binding private var path: [HostThreadID]
    private let onSettings: (() -> Void)?
    private let destination: (HostSession, ThreadSummary) -> Destination
    @State private var choosingHost = false

    public init(
        session: MultiHostModel,
        path: Binding<[HostThreadID]>,
        onSettings: (() -> Void)? = nil,
        @ViewBuilder destination: @escaping (HostSession, ThreadSummary) -> Destination
    ) {
        self.session = session
        self._path = path
        self.onSettings = onSettings
        self.destination = destination
    }

    public var body: some View {
        let adapter = HostThreadListAdapter(session: session)
        ThreadListView(
            threads: adapter.threads,
            workingThreads: adapter.workingThreads,
            hostLabel: adapter.hostLabel,
            onNewThread: { choosingHost = true },
            connection: session.connectionState,
            connectionStatus: session.statusConnectionState,
            connectionSince: session.hasMultipleHosts ? nil : session.sessions.first?.model.interruptedSince,
            connectionIsGraced: session.hasMultipleHosts,
            connectionSummary: session.hasMultipleHosts ? session.connectionSummary : nil,
            toastState: session.connectionToastNotice?.notice.state,
            toastID: session.connectionToastNotice?.notice.id,
            toastLabel: session.connectionToastLabel,
            onBackground: { for host in session.sessions { host.model.connectionToast.dismiss() } },
            path: Binding(get: { path.map(\.listID) }, set: { ids in
                path = ids.compactMap { adapter.resolve($0)?.id }
                if let id = path.last { session.lastUsedHostID = id.hostID }
            }),
            onCreate: { _, _ in },
            onRename: { thread, title in adapter.perform(thread) { $0.rename($1, to: title) } },
            onArchive: { thread, archived in adapter.perform(thread) { $0.setArchived($1, archived) } },
            onPin: { thread, pinned in adapter.perform(thread) { $0.setPinned($1, pinned) } },
            onRead: { thread, read in
                adapter.perform(thread) { model, original in
                    read ? model.markRead(original.id) : model.markUnread(original)
                }
            },
            onReadAll: session.markAllRead,
            onRefresh: {
                await withTaskGroup(of: Void.self) { group in
                    for host in session.sessions { group.addTask { await host.model.refresh() } }
                }
            },
            messageText: adapter.messageText,
            remoteMatches: adapter.remoteMatches,
            remoteQuery: adapter.remoteQuery,
            searchScope: session.searchScope,
            onSearchQueryChange: { query in
                for host in session.sessions { host.model.searchHost(query) }
            },
            exportMarkdown: adapter.markdown,
            onSettings: onSettings
        ) { thread in
            if let item = adapter.resolve(thread.id), let host = session.session(for: item.id.hostID) {
                HostThreadDestination(id: item.id, content: destination(host, item.thread))
                    .id(item.id)
            }
        }
        .sheet(isPresented: $choosingHost) {
            NewThreadPicker(session: session) { path = [$0] }
                .presentationDetents([.medium, .large])
        }
    }
}

/// Maps list search to the raw ID expected by the transcript while retaining its request UUID.
/// The qualified view identity above also prevents state leaking between colliding raw IDs.
private struct HostThreadDestination<Content: View>: View {
    let id: HostThreadID
    let content: Content
    @Environment(\.threadSearchRequest) private var searchRequest

    var body: some View {
        content.environment(\.threadSearchRequest, searchRequest.flatMap { request in
            guard request.threadId == id.listID else { return nil }
            return ThreadSearchRequest(threadId: id.threadID, query: request.query,
                                       eventId: request.eventId, id: request.id)
        })
    }
}

/// Mac sidebar uses the same adapter as the phone, including its menus and keyboard commands.
public struct MultiHostThreadSidebar: View {
    private let session: MultiHostModel
    @Binding private var selection: HostThreadID?
    private let onSearchSelect: ((HostThreadID?, ThreadSearchRequest?) -> Void)?
    @State private var choosingHost = false

    public init(
        session: MultiHostModel,
        selection: Binding<HostThreadID?>,
        onSearchSelect: ((HostThreadID?, ThreadSearchRequest?) -> Void)? = nil
    ) {
        self.session = session
        self._selection = selection
        self.onSearchSelect = onSearchSelect
    }

    public var body: some View {
        let adapter = HostThreadListAdapter(session: session)
        ThreadSidebar(
            threads: adapter.threads,
            workingThreads: adapter.workingThreads,
            hostLabel: adapter.hostLabel,
            onNewThread: { choosingHost = true },
            selection: Binding(get: { selection?.listID }, set: { id in
                selection = id.flatMap { adapter.resolve($0)?.id }
                if let selection { session.lastUsedHostID = selection.hostID }
            }),
            onCreate: { _, _ in },
            onRename: { thread, title in adapter.perform(thread) { $0.rename($1, to: title) } },
            onArchive: { thread, archived in adapter.perform(thread) { $0.setArchived($1, archived) } },
            onPin: { thread, pinned in adapter.perform(thread) { $0.setPinned($1, pinned) } },
            onRead: { thread, read in
                adapter.perform(thread) { model, original in
                    read ? model.markRead(original.id) : model.markUnread(original)
                }
            },
            onReadAll: session.markAllRead,
            messageText: adapter.messageText,
            remoteMatches: adapter.remoteMatches,
            remoteQuery: adapter.remoteQuery,
            searchScope: session.searchScope,
            onSearchQueryChange: { query in
                for host in session.sessions { host.model.searchHost(query) }
            },
            exportMarkdown: adapter.markdown,
            onSearchSelect: { request in
                let mapped = adapter.searchRequest(request)
                onSearchSelect?(mapped?.0, mapped?.1)
            }
        )
        .sheet(isPresented: $choosingHost) {
            NewThreadPicker(session: session) { selection = $0 }
        }
    }
}

extension MultiHostModel {
    public var searchScope: String {
        if sessions.contains(where: { $0.model.searchQuery.utf8.count > 128 }) {
            return "Downloaded conversations only · shorten search for host history"
        }
        if sessions.contains(where: { $0.model.searchIncomplete }) {
            return "Downloaded conversations and partial host results"
        }
        let available = sessions.filter { $0.model.canDeliver && $0.model.supportsHostSearch }
        guard !available.isEmpty else { return "Downloaded conversations only" }
        if available.count == sessions.count && available.allSatisfy({ $0.model.searchComplete }) {
            return "All host histories searched"
        }
        return available.allSatisfy({ $0.model.searchComplete })
            ? "Downloaded conversations and available host history"
            : "Downloaded conversations · searching available hosts…"
    }

    /// Most recent distinct outage owns the one visible toast. Keep dismissed notices in the
    /// ordering so an older host's still-running timer cannot make its toast reappear.
    public var connectionToastNotice: (host: HostSession, notice: ConnectionToastNotice)? {
        guard let newest = sessions.compactMap({ host in
            host.model.connectionToast.lastNotice.map { (host: host, notice: $0) }
        }).max(by: { $0.notice.sequence < $1.notice.sequence }),
              newest.host.model.connectionToast.notice?.id == newest.notice.id else { return nil }
        return newest
    }

    public var connectionToastLabel: String? {
        guard let shown = connectionToastNotice else { return nil }
        guard hasMultipleHosts else { return shown.notice.state.label }
        return switch shown.notice.state {
        case .connected: nil
        case .reconnecting: "Connecting to \(shown.host.label)…"
        case .offline: "\(shown.host.label) isn’t reachable"
        }
    }

    /// Status indicators start honest before pairing; after pairing they hold the last settled
    /// state through a short interruption. Toasts have separate initial visibility below.
    public var statusConnectionState: ConnectionState? {
        summarizedConnection { $0.model.link.state }
    }

    /// The worst link among the hosts. Each host first gets its own five-second grace, so a
    /// fresh interruption cannot borrow another host's elapsed time. With one host the list
    /// applies that host's grace using its interruption anchor. An update-required host counts
    /// as away only in the multi-host summary; alone it has its own update label elsewhere.
    public var connectionState: ConnectionState? {
        summarizedConnection { host in
            hasMultipleHosts ? host.model.toastLink.state
                : ConnectionState(state: host.model.state, ownerOnline: host.model.ownerOnline)
        }
    }

    private func summarizedConnection(_ state: (HostSession) -> ConnectionState) -> ConnectionState? {
        let states = sessions.map { host -> ConnectionState in
            if hasMultipleHosts, case .updateRequired = host.model.compatibility { return .offline }
            return state(host)
        }
        guard !states.isEmpty else { return nil }
        if states.contains(.offline) { return .offline }
        return states.contains(.reconnecting) ? .reconnecting : .connected
    }

    /// The merged list never borrows one host's status for the whole client. Counted from each
    /// host's ``ChatModel/link``, so one host's blip does not change the count.
    public var connectionSummary: String {
        let connected = sessions.filter {
            if case .updateRequired = $0.model.compatibility { return false }
            return $0.model.link.state == .connected
        }.count
        let updates = sessions.filter {
            if case .updateRequired = $0.model.compatibility { return true }
            return false
        }.count
        let summary = String(localized: "\(connected) of \(sessions.count) hosts connected")
        return updates == 0 ? summary : summary + " · " + String(localized: "\(updates) update required")
    }
}
