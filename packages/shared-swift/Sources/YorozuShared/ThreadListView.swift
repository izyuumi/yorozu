import SwiftUI

/// Most recently active first; archived threads are not shown. Both thread lists order
/// themselves with it, and an unsent draft leads because its activity is the moment it was made.
public func visibleThreads(_ threads: [ThreadSummary]) -> [ThreadSummary] {
    threads.filter { !$0.archived }.sorted { $0.lastActivity > $1.lastActivity }
}

/// The three groups the phone's list draws, in the order it draws them: pinned threads lead,
/// the archive is tucked away at the bottom, and everything else is the list proper. Each group
/// is most recently active first.
///
/// Pure, so a test can check the partition without a view.
public struct ThreadGroups: Equatable, Sendable {
    public var pinned: [ThreadSummary]
    public var recent: [ThreadSummary]
    public var archived: [ThreadSummary]

    public init(_ threads: [ThreadSummary]) {
        let live = visibleThreads(threads)
        pinned = live.filter(\.pinned)
        recent = live.filter { !$0.pinned }
        archived = threads.filter(\.archived).sorted { $0.lastActivity > $1.lastActivity }
    }

    /// True when there is nothing at all to draw, which is what puts the empty state up.
    public var isEmpty: Bool { pinned.isEmpty && recent.isEmpty && archived.isEmpty }
}

/// Whether a thread answers a search. `body` is everything said in it that the device still
/// holds, so a thread is findable by a word in it and not only by the title the runtime picked.
/// An empty query matches everything, which is what makes the unsearched list the whole list.
///
/// `body` is an autoclosure because gathering it means walking every cached event in the thread,
/// and the list redraws far more often than it is searched: with no query there is nothing to
/// search and the walk never happens.
public func threadMatches(
    _ thread: ThreadSummary,
    query: String,
    body: @autoclosure () -> String = ""
) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    if thread.displayTitle.localizedCaseInsensitiveContains(needle) { return true }
    if thread.lastMessage?.localizedCaseInsensitiveContains(needle) == true { return true }
    return body().localizedCaseInsensitiveContains(needle)
}

/// How stale the newest thread may be and still be the one an app opens itself.
public let openWindow: TimeInterval = 2 * 60 * 60

/// Which thread to open on launch, or on coming back to the foreground: the most recent one
/// while it is still warm, and `nil` — meaning start a fresh draft — once it has gone cold.
///
/// Pure, so both apps decide the same way and a test can move `now` rather than the clock.
public func threadToOpen(
    _ threads: [ThreadSummary],
    now: Date = Date(),
    within: TimeInterval = openWindow
) -> String? {
    guard let newest = visibleThreads(threads).first,
        now.timeIntervalSince1970 - newest.lastActivity / 1000 <= within
    else { return nil }
    return newest.id
}

/// The rename prompt both lists put behind their Rename action. Binding the thread rather than a
/// flag is what carries which row was picked; the field is seeded with the title it has now.
private struct RenameAlert: ViewModifier {
    @Binding var thread: ThreadSummary?
    let onRename: (ThreadSummary, String) -> Void

    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: thread) { _, picked in title = picked?.title ?? "" }
            .alert(
                "Rename thread",
                isPresented: Binding(get: { thread != nil }, set: { if !$0 { thread = nil } }),
                presenting: thread
            ) { picked in
                TextField("Title", text: $title)
                Button("Rename") { onRename(picked, title) }
                Button("Cancel", role: .cancel) {}
            }
    }
}

extension View {
    fileprivate func renameAlert(
        _ thread: Binding<ThreadSummary?>,
        onRename: @escaping (ThreadSummary, String) -> Void
    ) -> some View {
        modifier(RenameAlert(thread: thread, onRename: onRename))
    }
}

/// One thread as a row: what it is called, the last thing said in it, how long ago that was, and
/// a dot for as long as a reply has arrived in it that has not been read.
///
/// Nothing here is sized in points that Dynamic Type cannot move — the dot scales with the body
/// font and the two lines of text wrap by truncating, never by clipping.
struct ThreadRow: View {
    let thread: ThreadSummary
    var unread = false

    @ScaledMetric(relativeTo: .body) private var dot = 9

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(unread ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                .frame(width: dot, height: dot)
                // Nudged down to sit on the title's line rather than above it.
                .padding(.top, dot * 0.6)
                .accessibilityHidden(!unread)
                .accessibilityLabel("Unread")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(thread.displayTitle)
                        .font(.body.weight(unread ? .semibold : .regular))
                        // An untitled thread is one the runtime has not named yet, so its
                        // placeholder is drawn as the aside it is.
                        .foregroundStyle(
                            thread.title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                        )
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(
                        thread.lastActivityDate,
                        format: Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // The title gives way first: the time is short and always worth its width.
                    .layoutPriority(1)
                }
                if let preview = thread.lastMessage, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// How the phone reports the link to its Mac. Two independent facts collapsed into the one thing
/// worth saying: the relay has us or it does not, and behind it the Mac is there or it is not.
public enum ConnectionState: Sendable {
    case connected, reconnecting, offline

    public init(state: TransportState, ownerOnline: Bool) {
        switch state {
        // Joined or paired both mean the relay has us; the Mac's own presence is the other half.
        case .joined, .paired: self = ownerOnline ? .connected : .offline
        case .connecting, .closed: self = .reconnecting
        }
    }

    var label: String {
        switch self {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .offline: "Mac offline"
        }
    }

    var tint: Color {
        switch self {
        case .connected: .green
        case .reconnecting: .secondary
        case .offline: .red
        }
    }
}

/// The connection as a pill in the navigation bar rather than a banner across the top: the state
/// is almost always fine, and something that is almost always fine should not cost a strip of the
/// screen. A coloured dot carries it at a glance and the word behind it says which, so the pill
/// does not rely on colour alone.
struct ConnectionPill: View {
    let state: ConnectionState

    @ScaledMetric(relativeTo: .caption) private var dot = 7

    var body: some View {
        let content = HStack(spacing: 5) {
            Circle().fill(state.tint).frame(width: dot, height: dot)
            Text(state.label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mac connection: \(state.label)")

        // The bar is glass on 26, so the pill in it should be glass too; on 18 through 25 a thin
        // material is the nearest thing that still reads as a control rather than a label.
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(in: .capsule)
        } else {
            content.background(.thinMaterial, in: .capsule)
        }
    }
}

/// The phone's thread list: pinned threads first, then the rest newest first, with the archive
/// folded away at the bottom. `+` starts a fresh draft, a swipe pins or archives, a pull asks the
/// Mac for everything this device is behind on, and the search field looks through titles and
/// through what the device has cached of each thread.
///
/// It owns the navigation stack, so `destination` is the chat view to push and `path` is what
/// lets the app open a thread by itself on launch — set before the first frame, there is no
/// flash of the list on the way in. The path holds thread ids rather than summaries, so a draft
/// that becomes a real thread mid-push keeps drawing.
///
/// `onSettings` puts a gear beside the `+`. It is a callback rather than a view slot because the
/// bar belongs to the navigation stack this view owns, so a caller cannot reach it from outside;
/// optional because only the phone has a settings screen to open.
///
/// The Mac shows the same threads as a ``ThreadSidebar`` instead, because its chat lives beside
/// the list rather than on top of it.
public struct ThreadListView<Destination: View>: View {
    private let threads: [ThreadSummary]
    private let unread: Set<String>
    private let connection: ConnectionState?
    @Binding private var path: [String]
    private let onCreate: () -> Void
    private let onRename: (ThreadSummary, String) -> Void
    private let onArchive: (ThreadSummary, Bool) -> Void
    private let onPin: (ThreadSummary, Bool) -> Void
    private let onRefresh: (() async -> Void)?
    private let messageText: (String) -> String
    private let onSettings: (() -> Void)?
    private let destination: (ThreadSummary) -> Destination

    @State private var renaming: ThreadSummary?
    @State private var query = ""
    /// The archive opens closed: it is where threads go to stop being in the way.
    @State private var showArchived = false

    public init(
        threads: [ThreadSummary],
        unread: Set<String> = [],
        connection: ConnectionState? = nil,
        path: Binding<[String]>,
        onCreate: @escaping () -> Void,
        onRename: @escaping (ThreadSummary, String) -> Void,
        onArchive: @escaping (ThreadSummary, Bool) -> Void,
        onPin: @escaping (ThreadSummary, Bool) -> Void = { _, _ in },
        onRefresh: (() async -> Void)? = nil,
        messageText: @escaping (String) -> String = { _ in "" },
        onSettings: (() -> Void)? = nil,
        @ViewBuilder destination: @escaping (ThreadSummary) -> Destination
    ) {
        self.threads = threads
        self.unread = unread
        self.connection = connection
        self._path = path
        self.onCreate = onCreate
        self.onRename = onRename
        self.onArchive = onArchive
        self.onPin = onPin
        self.onRefresh = onRefresh
        self.messageText = messageText
        self.onSettings = onSettings
        self.destination = destination
    }

    /// The three groups, each already filtered by whatever is in the search field.
    private var groups: ThreadGroups {
        ThreadGroups(threads.filter { threadMatches($0, query: query, body: messageText($0.id)) })
    }

    public var body: some View {
        NavigationStack(path: $path) {
            let groups = groups
            List {
                if !groups.pinned.isEmpty {
                    Section("Pinned") { rows(groups.pinned) }
                }
                Section { rows(groups.recent) }
                if !groups.archived.isEmpty {
                    Section { archive(groups.archived) }
                }
            }
            .animation(.default, value: threads)
            .overlay { empty(groups) }
            .searchable(text: $query, prompt: "Search threads")
            .refreshable { await onRefresh?() }
            .navigationTitle("Threads")
            .toolbar {
                // `.principal` is the bar's middle, which is where the pill wants to be: beside
                // the title on the way in, and above the large one once it has settled.
                if let connection {
                    ToolbarItem(placement: .principal) { ConnectionPill(state: connection) }
                }
                if let onSettings {
                    ToolbarItem(placement: .navigation) {
                        Button("Settings", systemImage: "gear", action: onSettings)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New thread", systemImage: "square.and.pencil", action: onCreate)
                }
            }
            .navigationDestination(for: String.self) { id in
                if let thread = threads.first(where: { $0.id == id }) {
                    destination(thread)
                }
            }
        }
        .renameAlert($renaming, onRename: onRename)
    }

    /// The archive: shut by default, and the only place a thread comes back from.
    private func archive(_ threads: [ThreadSummary]) -> some View {
        let title: String = "Archived (\(threads.count))"
        return DisclosureGroup(isExpanded: $showArchived) {
            rows(threads)
        } label: {
            Label(title, systemImage: "archivebox").font(.subheadline)
        }
    }

    @ViewBuilder private func rows(_ threads: [ThreadSummary]) -> some View {
        ForEach(threads) { thread in
            NavigationLink(value: thread.id) {
                ThreadRow(thread: thread, unread: unread.contains(thread.id))
            }
            .swipeActions(edge: .leading) {
                if thread.archived {
                    Button("Unarchive", systemImage: "tray.and.arrow.up") { onArchive(thread, false) }
                        .tint(.blue)
                } else {
                    Button(
                        thread.pinned ? "Unpin" : "Pin",
                        systemImage: thread.pinned ? "pin.slash" : "pin"
                    ) { onPin(thread, !thread.pinned) }
                        .tint(.orange)
                }
            }
            .swipeActions(edge: .trailing) {
                if thread.archived {
                    Button("Unarchive", systemImage: "tray.and.arrow.up") { onArchive(thread, false) }
                        .tint(.blue)
                } else {
                    Button("Archive", systemImage: "archivebox", role: .destructive) {
                        onArchive(thread, true)
                    }
                    Button("Rename", systemImage: "pencil") { renaming = thread }
                }
            }
            .contextMenu {
                Button("Rename", systemImage: "pencil") { renaming = thread }
                if !thread.archived {
                    Button(
                        thread.pinned ? "Unpin" : "Pin",
                        systemImage: thread.pinned ? "pin.slash" : "pin"
                    ) { onPin(thread, !thread.pinned) }
                }
                Button(
                    thread.archived ? "Unarchive" : "Archive",
                    systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox"
                ) { onArchive(thread, !thread.archived) }
            }
        }
    }

    /// Nothing to show is two different situations, and saying which is the whole of the help:
    /// a search that found nothing, or a phone that has not been talked to yet.
    @ViewBuilder private func empty(_ groups: ThreadGroups) -> some View {
        if groups.isEmpty {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No threads yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start one and it will be here, on this phone and on your Mac.")
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

/// The Mac's thread list: the sidebar half of a split view, so picking a thread selects it
/// rather than pushing it. Same rows and same ordering, and rename and archive from the row's
/// context menu because there is nothing to swipe with a mouse.
public struct ThreadSidebar: View {
    private let threads: [ThreadSummary]
    @Binding private var selection: String?
    private let onCreate: () -> Void
    private let onRename: (ThreadSummary, String) -> Void
    private let onArchive: (ThreadSummary) -> Void

    @State private var renaming: ThreadSummary?

    public init(
        threads: [ThreadSummary],
        selection: Binding<String?>,
        onCreate: @escaping () -> Void,
        onRename: @escaping (ThreadSummary, String) -> Void,
        onArchive: @escaping (ThreadSummary) -> Void
    ) {
        self.threads = threads
        self._selection = selection
        self.onCreate = onCreate
        self.onRename = onRename
        self.onArchive = onArchive
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(visibleThreads(threads)) { thread in
                ThreadRow(thread: thread)
                    .tag(thread.id)
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { renaming = thread }
                        Button("Archive", systemImage: "archivebox") { onArchive(thread) }
                    }
            }
        }
        .navigationTitle("Threads")
        .toolbar {
            Button("New thread", systemImage: "plus", action: onCreate)
        }
        .renameAlert($renaming, onRename: onRename)
    }
}
