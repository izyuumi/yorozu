import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Screenshot-only list state. Empty in production.
@MainActor public enum ThreadListShowcase {
    public static var query = ""
}

/// Most recently active first; archived threads are not shown. Both thread lists order
/// themselves with it, and an unsent draft leads because its activity is the moment it was made.
public func visibleThreads(_ threads: [ThreadSummary]) -> [ThreadSummary] {
    threads.filter { !$0.archived }.sorted { $0.lastActivity > $1.lastActivity }
}

/// One dated section of the list. The four are fixed and always in this order: a list that
/// reorders its own headings is a list you have to read rather than scan.
public struct ThreadSection: Equatable, Sendable, Identifiable {
    public enum Group: String, CaseIterable, Sendable {
        case today
        case yesterday
        case thisWeek
        case earlier

        var title: String {
            switch self {
            case .today: String(localized: "Today")
            case .yesterday: String(localized: "Yesterday")
            case .thisWeek: String(localized: "This week")
            case .earlier: String(localized: "Earlier")
            }
        }
    }

    public var group: Group
    public var threads: [ThreadSummary]

    public var id: String { group.rawValue }
    public var title: String { group.title }

    public init(group: Group, threads: [ThreadSummary]) {
        self.group = group
        self.threads = threads
    }
}

/// Which heading a thread belongs under. A thread stamped in the future — a clock that is out
/// by a minute, which phones are — is today rather than a section of its own.
public func threadGroup(
    for date: Date,
    now: Date = Date(),
    calendar: Calendar = .current
) -> ThreadSection.Group {
    // Days rather than hours, and measured against `now` rather than against the clock, so the
    // sections are the ones the reader would name and a test can move the day.
    let today = calendar.startOfDay(for: now)
    let day = calendar.startOfDay(for: date)
    if day >= today { return .today }
    if day == calendar.date(byAdding: .day, value: -1, to: today) { return .yesterday }
    // The current week as the calendar counts it, which is what "this week" means to the person
    // reading it: the days since the week began, not the last seven days.
    if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
    return .earlier
}

/// Threads split into the dated sections the list draws, newest first within each and empty
/// sections left out. Pure, so the grouping is a table test rather than a screenshot.
public func threadSections(
    _ threads: [ThreadSummary],
    now: Date = Date(),
    calendar: Calendar = .current
) -> [ThreadSection] {
    let sorted = threads.sorted { $0.lastActivity > $1.lastActivity }
    return ThreadSection.Group.allCases.compactMap { group in
        let members = sorted.filter {
            threadGroup(for: $0.lastActivityDate, now: now, calendar: calendar) == group
        }
        return members.isEmpty ? nil : ThreadSection(group: group, threads: members)
    }
}

/// What the phone's list draws, in the order it draws it: pinned threads lead, then the rest
/// under a heading per stretch of time, and the archive is folded away at the bottom. Each
/// group is most recently active first.
///
/// Pure, so a test can check the partition without a view.
public struct ThreadGroups: Equatable, Sendable {
    public var pinned: [ThreadSummary]
    /// Everything unpinned and unarchived, newest first. ``sections`` is the same threads under
    /// their headings, which is what the phone draws.
    public var recent: [ThreadSummary]
    public var sections: [ThreadSection]
    public var archived: [ThreadSummary]

    public init(_ threads: [ThreadSummary], now: Date = Date(), calendar: Calendar = .current) {
        let live = visibleThreads(threads)
        pinned = live.filter(\.pinned)
        recent = live.filter { !$0.pinned }
        sections = threadSections(recent, now: now, calendar: calendar)
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

/// One short, whitespace-normalized window around a search match. Search results show the line
/// that matched instead of an unrelated latest-message preview.
public func searchExcerpt(in text: String, matching query: String, limit: Int = 96) -> String? {
    let haystack = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty, let match = haystack.range(of: needle, options: .caseInsensitive) else { return nil }
    let matchOffset = haystack.distance(from: haystack.startIndex, to: match.lowerBound)
    let startOffset = max(0, matchOffset - limit / 3)
    let start = haystack.index(haystack.startIndex, offsetBy: startOffset)
    let end = haystack.index(start, offsetBy: min(limit, haystack.distance(from: start, to: haystack.endIndex)))
    return (start > haystack.startIndex ? "…" : "") + String(haystack[start..<end])
        + (end < haystack.endIndex ? "…" : "")
}

/// How stale the newest thread may be and still be the one an app opens itself.
public let openWindow: TimeInterval = 2 * 60 * 60

/// One glanceable unit with no redundant “ago”, matching the compact row anatomy on both
/// platforms. Dates replace vague large relative numbers after a year.
public func compactThreadTime(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return String(localized: "now") }
    if seconds < 3_600 { return "\(max(1, Int(seconds / 60)))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
    if seconds < 604_800 { return "\(Int(seconds / 86_400))d" }
    if seconds < 2_629_800 { return "\(Int(seconds / 604_800))w" }
    if seconds < 31_557_600 { return "\(Int(seconds / 2_629_800))mo" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

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
    var working = false
    var preview: String? = nil
    var highlightQuery = ""

    @ScaledMetric(relativeTo: .body) private var dot = 9

    var body: some View {
        // Drawn from the thread's own two timestamps, which the runtime owns: reading on the
        // phone puts this dot out on the Mac too. See ``ThreadSummary/isUnread``.
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    highlightedText(thread.displayTitle)
                        .font(.body.weight(thread.isUnread ? .semibold : .regular))
                        // An untitled thread is one the runtime has not named yet, so its
                        // placeholder is drawn as the aside it is.
                        .foregroundStyle(
                            thread.title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                        )
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(compactThreadTime(thread.lastActivityDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // "1h" is for the eye; VoiceOver gets the phrase it stands for.
                    .accessibilityLabel(
                        thread.lastActivityDate.formatted(.relative(presentation: .named))
                    )
                    // The title gives way first: the time is short and always worth its width.
                    .layoutPriority(1)
                }
                if working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                } else if let preview = preview ?? thread.lastMessage, !preview.isEmpty {
                    highlightedText(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if thread.isUnread {
                Circle()
                    .fill(.tint)
                    .frame(width: dot, height: dot)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 2)
    }

    /// Search uses the same compact row, with the matching token carrying the only emphasis.
    /// Building one `Text` keeps truncation and Dynamic Type behavior identical to normal rows.
    private func highlightedText(_ text: String) -> Text {
        let needle = highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let match = text.range(of: needle, options: .caseInsensitive) else {
            return Text(text)
        }
        return Text(String(text[..<match.lowerBound]))
            // Weight rather than colour: orange on white falls short of 4.5:1, and the
            // secondary preview line would fall shorter still.
            + Text(String(text[match])).foregroundStyle(.primary).bold()
            + Text(String(text[match.upperBound...]))
    }
}

/// How the phone reports the link to its Mac. Two independent facts collapsed into the one thing
/// worth saying: the relay has us or it does not, and behind it the Mac is there or it is not.
public enum ConnectionState: Equatable, Sendable {
    case connected, reconnecting, offline

    public init(state: TransportState, ownerOnline: Bool) {
        switch state {
        // Joined or paired both mean the relay has us; the Mac's own presence is the other half.
        case .joined, .paired: self = ownerOnline ? .connected : .offline
        case .connecting, .closed: self = .reconnecting
        }
    }

    public var label: String {
        switch self {
        case .connected: String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting")
        case .offline: String(localized: "Mac offline")
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

/// UI-facing connection state. Backgrounding freezes the last label; a foreground disconnect
/// has to survive the grace period before it replaces that label. Recovery is always immediate.
@MainActor
@Observable
public final class ConnectionPresentation {
    public private(set) var state: ConnectionState
    private var pending: Task<Void, Never>?

    public init(_ state: ConnectionState) { self.state = state }

    public func update(
        _ actual: ConnectionState,
        active: Bool,
        delay: Duration = .seconds(3.2)
    ) {
        pending?.cancel()
        pending = nil
        guard active, actual != state else { return }
        guard actual != .connected else {
            state = actual
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.state = actual
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
    private let workingThreads: Set<String>
    private let connection: ConnectionState?
    @Binding private var path: [String]
    private let onCreate: () -> Void
    private let onRename: (ThreadSummary, String) -> Void
    private let onArchive: (ThreadSummary, Bool) -> Void
    private let onPin: (ThreadSummary, Bool) -> Void
    /// Marks a thread read, or back to unread. The runtime is the one that decides either way.
    private let onRead: (ThreadSummary, Bool) -> Void
    private let onReadAll: (() -> Void)?
    private let onRefresh: (() async -> Void)?
    private let messageText: (String) -> String
    private let exportMarkdown: ((ThreadSummary) -> String)?
    private let onSettings: (() -> Void)?
    private let destination: (ThreadSummary) -> Destination

    @State private var renaming: ThreadSummary?
    @State private var query = ThreadListShowcase.query
    /// The archive opens closed: it is where threads go to stop being in the way.
    @State private var showArchived = false
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// An iPad with room for two columns draws the list beside the chat, as the Mac does,
    /// rather than pushing the chat over it. A phone — and an iPad squeezed into Slide Over or
    /// a third of the screen — keeps the stack, so the same `path` drives both.
    private var splitLayout: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
        #else
            false
        #endif
    }

    /// The split view's selection is the top of the stack, so opening a thread from a
    /// notification or a share lands in the detail column the same way it lands on the stack.
    private var selection: Binding<String?> {
        Binding(get: { path.last }, set: { path = $0.map { [$0] } ?? [] })
    }

    public init(
        threads: [ThreadSummary],
        workingThreads: Set<String> = [],
        connection: ConnectionState? = nil,
        path: Binding<[String]>,
        onCreate: @escaping () -> Void,
        onRename: @escaping (ThreadSummary, String) -> Void,
        onArchive: @escaping (ThreadSummary, Bool) -> Void,
        onPin: @escaping (ThreadSummary, Bool) -> Void = { _, _ in },
        onRead: @escaping (ThreadSummary, Bool) -> Void = { _, _ in },
        onReadAll: (() -> Void)? = nil,
        onRefresh: (() async -> Void)? = nil,
        messageText: @escaping (String) -> String = { _ in "" },
        exportMarkdown: ((ThreadSummary) -> String)? = nil,
        onSettings: (() -> Void)? = nil,
        @ViewBuilder destination: @escaping (ThreadSummary) -> Destination
    ) {
        self.threads = threads
        self.workingThreads = workingThreads
        self.connection = connection
        self._path = path
        self.onCreate = onCreate
        self.onRename = onRename
        self.onArchive = onArchive
        self.onPin = onPin
        self.onRead = onRead
        self.onReadAll = onReadAll
        self.onRefresh = onRefresh
        self.messageText = messageText
        self.exportMarkdown = exportMarkdown
        self.onSettings = onSettings
        self.destination = destination
    }

    /// The three groups, each already filtered by whatever is in the search field.
    private var groups: ThreadGroups {
        ThreadGroups(threads.filter { threadMatches($0, query: query, body: messageText($0.id)) })
    }

    private var searchNeedle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var threadResults: [ThreadSummary] {
        guard !searchNeedle.isEmpty else { return [] }
        return threads.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchNeedle)
                || $0.lastMessage?.localizedCaseInsensitiveContains(searchNeedle) == true
        }
    }

    private var messageResults: [ThreadSummary] {
        guard !searchNeedle.isEmpty else { return [] }
        return threads.filter { messageText($0.id).localizedCaseInsensitiveContains(searchNeedle) }
    }

    public var body: some View {
        Group {
            #if os(iOS)
                if splitLayout {
                    NavigationSplitView {
                        list
                    } detail: {
                        NavigationStack { detail }
                    }
                } else {
                    stack
                }
            #else
                stack
            #endif
        }
        .renameAlert($renaming, onRename: onRename)
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: String.self) { id in
                    if let thread = threads.first(where: { $0.id == id }) {
                        destination(thread)
                    }
                }
        }
    }

    /// The detail column is never blank: with nothing chosen it says so, and says what to do.
    @ViewBuilder private var detail: some View {
        if let id = path.last, let thread = threads.first(where: { $0.id == id }) {
            destination(thread)
        } else {
            ContentUnavailableView(
                "No thread selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a thread, or start a new one.")
            )
        }
    }

    private var list: some View {
        let groups = groups
        return List(selection: splitLayout ? selection : nil) {
            if searchNeedle.isEmpty {
                if !groups.pinned.isEmpty {
                    Section("Pinned") { rows(groups.pinned) }
                }
                // Today, Yesterday, This week, Earlier: the headings are the only thing telling
                // a thread from this morning apart from one from last month at a glance.
                ForEach(groups.sections) { section in
                    Section(section.title) { rows(section.threads) }
                }
                if !groups.archived.isEmpty {
                    Section { archive(groups.archived) }
                }
            } else {
                if !threadResults.isEmpty {
                    Section("Threads") { rows(threadResults) }
                }
                if !messageResults.isEmpty {
                    Section("Messages") {
                        rows(messageResults) { searchExcerpt(in: messageText($0.id), matching: searchNeedle) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.vertical, 4)
        .animation(.default, value: threads)
        .overlay { empty(groups) }
        // A search modifier on the root navigation stack otherwise follows pushed chats:
        // pulling a transcript down reveals "Search threads" above the conversation.
        .threadListSearch(text: $query, enabled: splitLayout || path.isEmpty)
        .refreshable { await onRefresh?() }
        .navigationTitle("Threads")
        .toolbar {
            if let onSettings {
                ToolbarItem(placement: .navigation) {
                    Button(action: onSettings) {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "gearshape")
                            if let connection {
                                Circle()
                                    .fill(connection.tint)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                            }
                        }
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityValue(connection.map { "Mac connection: \($0.label)" } ?? "")
                }
            }
            #if os(iOS)
                ToolbarItem(placement: .primaryAction) { newThreadButton }
                if threads.contains(where: \.isUnread), let onReadAll {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Mark all as read", systemImage: "envelope.open", action: onReadAll)
                    }
                }
            #endif
            #if os(macOS)
                ToolbarItem(placement: .primaryAction) { newThreadButton }
            #endif
        }
    }

    /// Native toolbar button on both platforms. Keeping it in the bar leaves the final thread
    /// and the always-visible search field unobstructed.
    @ViewBuilder private var newThreadButton: some View {
        Button("New thread", systemImage: "square.and.pencil", action: onCreate)
            // ⌘N on an iPad keyboard; the Mac's File menu carries its own — see ``ThreadCommands``.
            #if os(iOS)
                .keyboardShortcut("n")
            #endif
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

    @ViewBuilder private func rows(
        _ threads: [ThreadSummary],
        preview: @escaping (ThreadSummary) -> String? = { _ in nil }
    ) -> some View {
        ForEach(threads) { thread in
            NavigationLink(value: thread.id) {
                ThreadRow(
                    thread: thread,
                    working: workingThreads.contains(thread.id),
                    preview: preview(thread),
                    highlightQuery: searchNeedle
                )
            }
            .swipeActions(edge: .leading) {
                if thread.archived {
                    Button("Restore", systemImage: "tray.and.arrow.up") { onArchive(thread, false) }
                        .tint(.blue)
                } else {
                    if thread.isUnread {
                        Button("Mark as read", systemImage: "envelope.open") { onRead(thread, true) }
                            .tint(.blue)
                    }
                    Button(
                        thread.pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                        systemImage: thread.pinned ? "pin.slash" : "pin"
                    ) { onPin(thread, !thread.pinned) }
                        .tint(.orange)
                }
            }
            .swipeActions(edge: .trailing) {
                if thread.archived {
                    Button("Restore", systemImage: "tray.and.arrow.up") { onArchive(thread, false) }
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
                        thread.pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                        systemImage: thread.pinned ? "pin.slash" : "pin"
                    ) { onPin(thread, !thread.pinned) }
                }
                readButton(thread)
                if let exportMarkdown {
                    ExportThreadButton(title: thread.displayTitle) { exportMarkdown(thread) }
                }
                Button(
                    thread.archived ? String(localized: "Restore") : String(localized: "Archive"),
                    systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox"
                ) { onArchive(thread, !thread.archived) }
            }
        }
    }

    /// Marking read by hand, both ways round. A thread the agent has never spoken in cannot be
    /// made unread — there is nothing in it to be unread about — so it is offered neither.
    @ViewBuilder private func readButton(_ thread: ThreadSummary) -> some View {
        if thread.isUnread {
            Button("Mark as read", systemImage: "envelope.open") { onRead(thread, true) }
        } else if thread.lastAgentAt != nil {
            Button("Mark as unread", systemImage: "envelope.badge") { onRead(thread, false) }
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

extension View {
    @ViewBuilder fileprivate func threadListSearch(text: Binding<String>, enabled: Bool) -> some View {
        if enabled {
            #if os(iOS)
                searchable(
                    text: text,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search threads"
                )
            #else
                searchable(text: text, prompt: "Search threads")
            #endif
        } else {
            self
        }
    }
}

/// The Mac's thread list: the sidebar half of a split view, so picking a thread selects it
/// rather than pushing it. Same rows, same ordering and the same dated headings the phone
/// draws — pinned first, then a section per stretch of time, with the archive folded away at
/// the bottom — because a list that groups itself one way on the phone and another way on the
/// Mac is two lists to learn.
///
/// The row actions are all in the context menu rather than behind a swipe: there is nothing to
/// swipe with a pointer. Search is the sidebar's own field, over titles and over what each
/// thread's cached messages say, exactly as on the phone.
public struct ThreadSidebar: View {
    private let threads: [ThreadSummary]
    private let workingThreads: Set<String>
    @Binding private var selection: String?
    private let onCreate: () -> Void
    private let onRename: (ThreadSummary, String) -> Void
    private let onArchive: (ThreadSummary, Bool) -> Void
    private let onPin: (ThreadSummary, Bool) -> Void
    /// Marks a thread read, or back to unread. The runtime is the one that decides either way.
    private let onRead: (ThreadSummary, Bool) -> Void
    private let messageText: (String) -> String
    private let exportMarkdown: ((ThreadSummary) -> String)?

    @State private var renaming: ThreadSummary?
    @State private var query = ""
    @State private var hoveredThreadID: String?
    /// The archive opens closed: it is where threads go to stop being in the way.
    @State private var showArchived = false

    public init(
        threads: [ThreadSummary],
        workingThreads: Set<String> = [],
        selection: Binding<String?>,
        onCreate: @escaping () -> Void,
        onRename: @escaping (ThreadSummary, String) -> Void,
        onArchive: @escaping (ThreadSummary, Bool) -> Void,
        onPin: @escaping (ThreadSummary, Bool) -> Void = { _, _ in },
        onRead: @escaping (ThreadSummary, Bool) -> Void = { _, _ in },
        messageText: @escaping (String) -> String = { _ in "" },
        exportMarkdown: ((ThreadSummary) -> String)? = nil
    ) {
        self.threads = threads
        self.workingThreads = workingThreads
        self._selection = selection
        self.onCreate = onCreate
        self.onRename = onRename
        self.onArchive = onArchive
        self.onPin = onPin
        self.onRead = onRead
        self.messageText = messageText
        self.exportMarkdown = exportMarkdown
    }

    private var groups: ThreadGroups {
        ThreadGroups(threads.filter { threadMatches($0, query: query, body: messageText($0.id)) })
    }

    public var body: some View {
        let groups = groups
        List(selection: $selection) {
            if !groups.pinned.isEmpty {
                Section("Pinned") { rows(groups.pinned) }
            }
            ForEach(groups.sections) { section in
                Section(section.title) { rows(section.threads) }
            }
            if !groups.archived.isEmpty {
                Section { archive(groups.archived) }
            }
        }
        .animation(.default, value: threads)
        .overlay { empty(groups) }
        // In the sidebar itself rather than in the toolbar: the chat next to it has a search
        // field of its own, and two searchable views in one window fight over the toolbar.
        .searchable(text: $query, placement: .sidebar, prompt: "Search threads")
        .navigationTitle("Threads")
        .toolbar {
            // The same compose glyph the phone's list and every Mac mail or notes app use.
            Button("New thread", systemImage: "square.and.pencil", action: onCreate)
        }
        .renameAlert($renaming, onRename: onRename)
        #if os(macOS)
            // What the Mac's File menu acts on. Published from here because a new thread is the
            // list's business and outlives whichever one is open — see ``ThreadCommands``.
            .focusedSceneValue(\.threadCommands, ThreadCommands(newThread: onCreate))
            // Delete on a selected row puts it away, as it does in every Mac list. Archiving
            // rather than deleting, because that is the only removal this list has — and it
            // is undone from the Archived section rather than with ⌘Z.
            .onDeleteCommand {
                guard let thread = threads.first(where: { $0.id == selection }), !thread.archived
                else { return }
                onArchive(thread, true)
            }
        #endif
    }

    private func archive(_ threads: [ThreadSummary]) -> some View {
        DisclosureGroup(isExpanded: $showArchived) {
            rows(threads)
        } label: {
            Label("Archived (\(threads.count))", systemImage: "archivebox").font(.subheadline)
        }
    }

    @ViewBuilder private func rows(_ threads: [ThreadSummary]) -> some View {
        ForEach(threads) { thread in
            HStack(spacing: LayoutMetrics.tight) {
                ThreadRow(thread: thread, working: workingThreads.contains(thread.id))
                Menu { menu(thread) } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hoveredThreadID == thread.id ? 1 : 0)
                .allowsHitTesting(hoveredThreadID == thread.id)
                .accessibilityLabel("Thread actions")
            }
            .tag(thread.id)
            .contentShape(.rect)
            .onHover { hoveredThreadID = $0 ? thread.id : nil }
            .contextMenu { menu(thread) }
        }
    }

    /// The same actions the phone offers, and in the same order: the phone has them split
    /// between two swipes and a long press, and the Mac has one menu to put them all in.
    @ViewBuilder private func menu(_ thread: ThreadSummary) -> some View {
        Button("Rename", systemImage: "pencil") { renaming = thread }
        if !thread.archived {
            Button(
                thread.pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                systemImage: thread.pinned ? "pin.slash" : "pin"
            ) { onPin(thread, !thread.pinned) }
        }
        // A thread the agent has never spoken in cannot be made unread: nothing in it is news.
        if thread.isUnread {
            Button("Mark as read", systemImage: "envelope.open") { onRead(thread, true) }
        } else if thread.lastAgentAt != nil {
            Button("Mark as unread", systemImage: "envelope.badge") { onRead(thread, false) }
        }
        // Built here rather than up front: rendering a whole thread as Markdown is work, and
        // a menu that is never opened should not have done it.
        if let exportMarkdown {
            ExportThreadButton(title: thread.displayTitle) { exportMarkdown(thread) }
        }
        Button(
            thread.archived ? String(localized: "Restore") : String(localized: "Archive"),
            systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox"
        ) { onArchive(thread, !thread.archived) }
    }

    @ViewBuilder private func empty(_ groups: ThreadGroups) -> some View {
        if groups.isEmpty {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No threads yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start one and it will be here, on this Mac and on your phone.")
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
