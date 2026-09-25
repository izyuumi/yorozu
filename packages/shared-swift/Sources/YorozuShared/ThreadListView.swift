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
    if !searchRanges(in: thread.displayTitle, term: needle).isEmpty { return true }
    if !searchRanges(in: thread.lastMessage ?? "", term: needle).isEmpty { return true }
    // Who answers it and where: "claude" finds every Claude Code thread, "yorozu" the repo's.
    if !searchRanges(in: (thread.agent ?? .yorozu).label, term: needle).isEmpty { return true }
    if !searchRanges(in: thread.repoName ?? "", term: needle).isEmpty { return true }
    return !searchRanges(in: body(), term: needle).isEmpty
}

/// One short, whitespace-normalized window around a search match. Search results show the line
/// that matched instead of an unrelated latest-message preview.
public func searchExcerpt(in text: String, matching query: String, limit: Int = 96) -> String? {
    let haystack = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty, let match = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
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
/// platforms. Seconds show under two minutes, where a live reply is still landing; dates
/// replace vague large relative numbers after a year.
public func compactThreadTime(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 120 { return "1m \(Int(seconds) - 60)s" }
    if seconds < 3_600 { return "\(Int(seconds / 60))m" }
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
/// font. Mac titles can wrap onto a second line; previews remain a compact single line.
struct ThreadRow: View {
    let thread: ThreadSummary
    var working = false
    var preview: String? = nil
    var highlightQuery = ""
    var selected = false
    var chevron = false
    var hostLabel: String? = nil

    @ScaledMetric(relativeTo: .body) private var dot = 9
    @ScaledMetric(relativeTo: .body) private var mark = 16

    var body: some View {
        // Drawn from the thread's own two timestamps, which the runtime owns: reading on the
        // phone puts this dot out on the Mac too. See ``ThreadSummary/isUnread``.
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Every thread wears its agent's mark, Yorozu's own knot included.
                    AgentIdentifierView(thread.agent ?? .yorozu, size: mark)
                    highlightedText(thread.displayTitle)
                        .font(.body.weight(thread.isUnread ? .semibold : .regular))
                        // An untitled thread is one the runtime has not named yet, so its
                        // placeholder is drawn as the aside it is.
                        .foregroundStyle(
                            thread.title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                        )
                        #if os(macOS)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(thread.displayTitle)
                        #else
                            .lineLimit(1)
                        #endif
                    Spacer(minLength: 0)
                    // Ticks each second only while seconds are on show.
                    TimelineView(.periodic(from: .now, by: thread.lastActivityDate > .now - 120 ? 1 : 60)) {
                        Text(compactThreadTime(thread.lastActivityDate, now: $0.date))
                    }
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
                } else if let repo = thread.repoName {
                    // Nothing said yet: the repo is the one thing worth a second line.
                    Text(repo)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let hostLabel {
                    Text(hostLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // A card waiting on the user outranks an unread reply: it is the one asking.
            if thread.awaitingApproval == true {
                Image(systemName: "hand.raised")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Waiting for your approval")
            } else if thread.isUnread {
                Circle()
                    .fill(.tint)
                    .frame(width: dot, height: dot)
                    .accessibilityLabel("Unread")
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LayoutMetrics.stack)
        .padding(.vertical, 10)
        .background(
            selected ? Color.clear : YorozuPalette.paper,
            in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
                .strokeBorder(selected ? Color.clear : YorozuPalette.rule.opacity(0.64), lineWidth: 0.75)
        }
        // VoiceOver hears the agent and repo once, up front, rather than as a glyph mid-row.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// "Claude Code, yorozu: Fix the flaky test. Done: …" — and just the title for Yorozu's own.
    private var accessibilitySummary: String {
        var parts: [String] = []
        if let hostLabel { parts.append(hostLabel) }
        if let agent = thread.agent, agent != .yorozu {
            parts.append([agent.label, thread.repoName].compactMap { $0 }.joined(separator: ", "))
        }
        parts.append(thread.displayTitle)
        if working { parts.append(String(localized: "Working")) }
        else if let preview = preview ?? thread.lastMessage, !preview.isEmpty { parts.append(preview) }
        if thread.awaitingApproval == true { parts.append(String(localized: "Waiting for your approval")) }
        else if thread.isUnread { parts.append(String(localized: "Unread")) }
        return parts.joined(separator: ". ")
    }

    /// Search uses the same compact row, with the matching token carrying the only emphasis.
    /// Building one `Text` keeps truncation and Dynamic Type behavior identical to normal rows.
    private func highlightedText(_ text: String) -> Text {
        let needle = highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let match = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
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
        case .connected: YorozuPalette.sage
        case .reconnecting: .secondary
        case .offline: .red
        }
    }
}

/// UI-facing connection state, kept apart from raw transport availability. A lost link opens a
/// grace window rather than saying anything; if the link is back inside it, nothing was said.
/// The window is anchored to when the interruption began, so a link that goes from reconnecting
/// to Mac-offline four seconds in is declared at five, not nine — and separate short losses each
/// open their own window rather than adding up. Backgrounding freezes the last label and forgets
/// the window: the foreground re-evaluates from scratch, so a timer that ran down while suspended
/// cannot flash a stale state. Recovery is always immediate and needs no window of its own.
@MainActor
@Observable
public final class ConnectionPresentation {
    /// How long a link can be gone before the user hears about it.
    public static let grace: Duration = .seconds(5)

    public private(set) var state: ConnectionState
    private var pending: Task<Void, Never>?
    private var interruptedAt: ContinuousClock.Instant?

    public init(_ state: ConnectionState) { self.state = state }

    public func update(_ actual: ConnectionState, active: Bool, grace: Duration = grace) {
        pending?.cancel()
        pending = nil
        guard active else {
            interruptedAt = nil
            return
        }
        if actual == .connected {
            interruptedAt = nil
            state = actual
            return
        }
        guard actual != state else { return }
        let since = interruptedAt ?? .now
        interruptedAt = since
        pending = Task { [weak self] in
            try? await Task.sleep(until: since.advanced(by: grace), clock: .continuous)
            // Cancelled means a newer update owns the outcome; this one must not touch it.
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
    /// The multi-host list says which hosts are missing rather than "Mac offline".
    var label: String? = nil

    @ScaledMetric(relativeTo: .caption) private var dot = 7

    var body: some View {
        let content = HStack(spacing: 5) {
            Circle().fill(state.tint).frame(width: dot, height: dot)
            Text(label ?? state.label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mac connection: \(label ?? state.label)")

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
/// `onSettings` puts a gear in the list toolbar. It is a callback rather than a view slot because the
/// bar belongs to the navigation stack this view owns, so a caller cannot reach it from outside;
/// optional because only the phone has a settings screen to open.
///
/// The Mac shows the same threads as a ``ThreadSidebar`` instead, because its chat lives beside
/// the list rather than on top of it.
public struct ThreadListView<Destination: View>: View {
    private let threads: [ThreadSummary]
    private let workingThreads: Set<String>
    private let hostLabel: (String) -> String?
    private let onNewThread: (() -> Void)?
    private let connection: ConnectionState?
    private let connectionSummary: String?
    @Binding private var path: [String]
    /// Where a coding agent can be started. Empty means the picker offers Yorozu alone.
    private let projects: [ProjectFolder]
    private let projectListStatus: ProjectListStatus
    private let onRefreshProjects: (() async -> Void)?
    /// Starts a thread for the chosen agent, in the chosen folder when it needs one.
    private let onCreate: (ThreadAgent, String?) -> Void
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
    @State private var searchRequest: ThreadSearchRequest?
    /// The archive opens closed: it is where threads go to stop being in the way.
    @State private var showArchived = false
    @State private var choosingAgent = NewThreadShowcase.agent != nil
    /// What the list says about the link, which lags what the transport says by
    /// ``ConnectionPresentation/grace`` on the way down and not at all on the way up.
    @State private var presentation = ConnectionPresentation(.connected)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Nil with no host to report on; otherwise the graced state.
    private var shownConnection: ConnectionState? { connection == nil ? nil : presentation.state }

    /// Regular width draws the list beside the chat, including on iPhone Duo's inner display.
    /// Compact width keeps the stack; the same `path` drives both layouts during resizing.
    private var splitLayout: Bool {
        #if os(iOS)
            sizeClass == .regular
        #else
            false
        #endif
    }

    private var hasSelectedThread: Bool {
        guard let id = path.last else { return false }
        return threads.contains { $0.id == id }
    }

    private var settingsPlacement: ToolbarItemPlacement {
        #if os(iOS)
            .topBarTrailing
        #else
            .navigation
        #endif
    }

    /// The split view's selection is the top of the stack, so opening a thread from a
    /// notification or a share lands in the detail column the same way it lands on the stack.
    private var selection: Binding<String?> {
        Binding(get: { path.last }, set: { id in
            if let id { prepareSearchNavigation(id) }
            else { searchRequest = nil }
            path = id.map { [$0] } ?? []
        })
    }

    /// Only writes made by navigation controls carry list-search intent. A notification or
    /// restored session writes the parent's binding directly and keeps its own destination.
    private var navigationPath: Binding<[String]> {
        Binding(get: { path }, set: { value in
            if let id = value.last { prepareSearchNavigation(id) }
            else { searchRequest = nil }
            path = value
        })
    }

    public init(
        threads: [ThreadSummary],
        workingThreads: Set<String> = [],
        hostLabel: @escaping (String) -> String? = { _ in nil },
        onNewThread: (() -> Void)? = nil,
        connection: ConnectionState? = nil,
        connectionSummary: String? = nil,
        path: Binding<[String]>,
        projects: [ProjectFolder] = [],
        projectListStatus: ProjectListStatus = .ready,
        onRefreshProjects: (() async -> Void)? = nil,
        onCreate: @escaping (ThreadAgent, String?) -> Void,
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
        self.hostLabel = hostLabel
        self.onNewThread = onNewThread
        self.connection = connection
        self.connectionSummary = connectionSummary
        self._path = path
        self.projects = projects
        self.projectListStatus = projectListStatus
        self.onRefreshProjects = onRefreshProjects
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
        ThreadGroups(threads.filter {
            threadMatches($0, query: query, body: messageText($0.id))
                || !searchRanges(in: hostLabel($0.id) ?? "", term: query).isEmpty
        })
    }

    private var searchNeedle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchResults: ThreadSearchResults {
        ThreadSearchResults(threads: threads, query: query, metadataText: { hostLabel($0) ?? "" }, messageText: messageText)
    }

    private var threadResults: [ThreadSummary] { searchResults.threads }
    private var messageResults: [ThreadSummary] { searchResults.messages }

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
        .onChange(of: path) { _, value in
            if searchRequest?.threadId != value.last { searchRequest = nil }
        }
        // Incoming replies change the toolbar's unread actions. Keep the presenter on the
        // navigation container so rebuilding a button cannot hide or reset an open picker.
        .sheet(isPresented: $choosingAgent) {
            NewThreadPicker(projects: projects, status: projectListStatus, onRefresh: onRefreshProjects, onStart: onCreate)
                .presentationDetents([.medium, .large])
        }
    }

    private func newThread() {
        if let onNewThread { onNewThread() }
        else { choosingAgent = true }
    }

    private func prepareSearchNavigation(_ id: String) {
        guard !searchNeedle.isEmpty else {
            searchRequest = nil
            return
        }
        searchRequest = searchRanges(in: messageText(id), term: searchNeedle).isEmpty
            ? nil : ThreadSearchRequest(threadId: id, query: searchNeedle)
    }

    private var stack: some View {
        NavigationStack(path: navigationPath) {
            list
                .navigationDestination(for: String.self) { id in
                    if let thread = threads.first(where: { $0.id == id }) {
                        destination(thread).environment(\.threadSearchRequest, searchRequest)
                    }
                }
        }
    }

    /// The detail column is never blank: with nothing chosen it says so, and says what to do.
    @ViewBuilder private var detail: some View {
        if let id = path.last, let thread = threads.first(where: { $0.id == id }) {
            destination(thread).environment(\.threadSearchRequest, searchRequest)
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
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
        .contentMargins(.vertical, LayoutMetrics.inner)
        .animation(.default, value: threads)
        .overlay { empty(groups) }
        // A toast over the list, not a row in it: the link coming and going must not move a
        // single thread, heading or scroll anchor. One view for the whole interruption, its
        // label updated in place, gone the moment the link is back — and never there at all
        // for an interruption shorter than the grace.
        .overlay(alignment: .top) {
            if let shownConnection, shownConnection != .connected {
                ConnectionPill(state: shownConnection, label: connectionSummary)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .default, value: shownConnection)
        .onChange(of: connection, initial: true) { _, actual in
            presentation.update(actual ?? .connected, active: scenePhase != .background)
        }
        .onChange(of: scenePhase) { _, phase in
            presentation.update(connection ?? .connected, active: phase != .background)
        }
        // Once per declared change, not once per retry: the presentation only moves after the
        // grace, or on recovery.
        .onChange(of: shownConnection) { old, state in
            guard old != nil, let state else { return }
            AccessibilityNotification.Announcement(connectionSummary ?? state.label).post()
        }
        // A search modifier on the root navigation stack otherwise follows pushed chats:
        // pulling a transcript down reveals "Search threads" above the conversation.
        .threadListSearch(text: $query, enabled: splitLayout || path.isEmpty)
        .refreshable { await onRefresh?() }
        .navigationTitle("Threads")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let onSettings {
                ToolbarItem(placement: settingsPlacement) {
                    Button(action: onSettings) {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "gearshape")
                            if let shownConnection {
                                Circle()
                                    .fill(shownConnection.tint)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                            }
                        }
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityValue(connectionSummary ?? shownConnection.map { "Mac connection: \($0.label)" } ?? "")
                }
            }
            #if os(iOS)
                if threads.contains(where: \.isUnread), let onReadAll {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Mark all as read", systemImage: "envelope.open", action: onReadAll)
                    }
                }
                // A selected chat already has New session in its own toolbar.
                if !splitLayout || !hasSelectedThread {
                    if #available(iOS 27.1, *), !splitLayout {
                        // The compact Duo bar puts this at the reachable lower edge.
                        ToolbarItem(placement: .bottomBar) { newThreadButton }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) { newThreadButton }
                    }
                }
            #endif
            #if os(macOS)
                ToolbarItem(placement: .primaryAction) { newThreadButton }
            #endif
        }
    }

    /// Native toolbar button on both platforms. Keeping it in the bar leaves the final thread
    /// and the always-visible search field unobstructed. It asks who should answer — one tap
    /// for Yorozu, two for a coding agent in a recent folder.
    @ViewBuilder private var newThreadButton: some View {
        Button("New thread", systemImage: "square.and.pencil", action: newThread)
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
        // Match the thread rows: the list draws on the canvas, not the system row fill.
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private func rows(
        _ threads: [ThreadSummary],
        preview: @escaping (ThreadSummary) -> String? = { _ in nil }
    ) -> some View {
        ForEach(threads) { thread in
            let row = ThreadRow(
                thread: thread,
                working: workingThreads.contains(thread.id),
                preview: preview(thread),
                highlightQuery: searchNeedle,
                selected: splitLayout && path.last == thread.id,
                chevron: !splitLayout,
                hostLabel: hostLabel(thread.id)
            )
            Button {
                prepareSearchNavigation(thread.id)
                path = [thread.id]
            } label: { row }
            .buttonStyle(.plain)
            .tag(thread.id)
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
        if searchNeedle.isEmpty ? groups.isEmpty : searchResults.isEmpty {
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
                    placement: .navigationBarDrawer(displayMode: .automatic),
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
    private let hostLabel: (String) -> String?
    private let onNewThread: (() -> Void)?
    @Binding private var selection: String?
    /// Where a coding agent can be started. Empty means the picker offers Yorozu alone.
    private let projects: [ProjectFolder]
    private let projectListStatus: ProjectListStatus
    private let onRefreshProjects: (() async -> Void)?
    /// Starts a thread for the chosen agent, in the chosen folder when it needs one.
    private let onCreate: (ThreadAgent, String?) -> Void
    private let onRename: (ThreadSummary, String) -> Void
    private let onArchive: (ThreadSummary, Bool) -> Void
    private let onPin: (ThreadSummary, Bool) -> Void
    /// Marks a thread read, or back to unread. The runtime is the one that decides either way.
    private let onRead: (ThreadSummary, Bool) -> Void
    private let onReadAll: (() -> Void)?
    private let messageText: (String) -> String
    private let exportMarkdown: ((ThreadSummary) -> String)?
    private let onSearchSelect: ((ThreadSearchRequest?) -> Void)?

    @State private var renaming: ThreadSummary?
    @State private var query = ThreadListShowcase.query
    @State private var searchThreadID: String?
    /// The archive opens closed: it is where threads go to stop being in the way.
    @State private var showArchived = false
    @State private var choosingAgent = NewThreadShowcase.agent != nil

    public init(
        threads: [ThreadSummary],
        workingThreads: Set<String> = [],
        hostLabel: @escaping (String) -> String? = { _ in nil },
        onNewThread: (() -> Void)? = nil,
        selection: Binding<String?>,
        projects: [ProjectFolder] = [],
        projectListStatus: ProjectListStatus = .ready,
        onRefreshProjects: (() async -> Void)? = nil,
        onCreate: @escaping (ThreadAgent, String?) -> Void,
        onRename: @escaping (ThreadSummary, String) -> Void,
        onArchive: @escaping (ThreadSummary, Bool) -> Void,
        onPin: @escaping (ThreadSummary, Bool) -> Void = { _, _ in },
        onRead: @escaping (ThreadSummary, Bool) -> Void = { _, _ in },
        onReadAll: (() -> Void)? = nil,
        messageText: @escaping (String) -> String = { _ in "" },
        exportMarkdown: ((ThreadSummary) -> String)? = nil,
        onSearchSelect: ((ThreadSearchRequest?) -> Void)? = nil
    ) {
        self.threads = threads
        self.workingThreads = workingThreads
        self.hostLabel = hostLabel
        self.onNewThread = onNewThread
        self._selection = selection
        self.projects = projects
        self.projectListStatus = projectListStatus
        self.onRefreshProjects = onRefreshProjects
        self.onCreate = onCreate
        self.onRename = onRename
        self.onArchive = onArchive
        self.onPin = onPin
        self.onRead = onRead
        self.onReadAll = onReadAll
        self.messageText = messageText
        self.exportMarkdown = exportMarkdown
        self.onSearchSelect = onSearchSelect
    }

    private var groups: ThreadGroups {
        ThreadGroups(threads)
    }

    private var searchNeedle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchResults: ThreadSearchResults {
        ThreadSearchResults(threads: threads, query: query, metadataText: { hostLabel($0) ?? "" }, messageText: messageText)
    }

    private var navigationSelection: Binding<String?> {
        Binding(get: { selection }, set: { id in
            if let id { prepareSearchNavigation(id) }
            else {
                searchThreadID = nil
                onSearchSelect?(nil)
            }
            selection = id
        })
    }

    public var body: some View {
        let groups = groups
        List(selection: navigationSelection) {
            if searchNeedle.isEmpty {
                if !groups.pinned.isEmpty {
                    Section("Pinned") { rows(groups.pinned) }
                }
                ForEach(groups.sections) { section in
                    Section(section.title) { rows(section.threads) }
                }
                if !groups.archived.isEmpty {
                    Section { archive(groups.archived) }
                }
            } else {
                let results = searchResults
                if !results.threads.isEmpty {
                    Section("Threads") { rows(results.threads) }
                }
                if !results.messages.isEmpty {
                    Section("Messages") {
                        rows(results.messages) { searchExcerpt(in: messageText($0.id), matching: searchNeedle) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
        .contentMargins(.vertical, LayoutMetrics.inner)
        .animation(.default, value: threads)
        .overlay { empty(groups) }
        // In the sidebar itself rather than in the toolbar: the chat next to it has a search
        // field of its own, and two searchable views in one window fight over the toolbar.
        .searchable(text: $query, placement: .sidebar, prompt: "Search threads")
        .navigationTitle("Threads")
        .toolbar {
            if threads.contains(where: \.isUnread), let onReadAll {
                Button("Mark all as read", systemImage: "envelope.open", action: onReadAll)
            }
            // The same compose glyph the phone's list and every Mac mail or notes app use. It
            // asks who should answer in the same modal as the keyboard shortcut — and, on a
            // client, in the caller's own picker, the one that knows the hosts and their folders.
            Button("New thread", systemImage: "square.and.pencil", action: newThread)
        }
        .renameAlert($renaming, onRename: onRename)
        .onChange(of: selection) { _, id in
            if searchThreadID != id {
                searchThreadID = nil
                onSearchSelect?(nil)
            }
        }
        .sheet(isPresented: $choosingAgent) {
            NewThreadPicker(projects: projects, status: projectListStatus, onRefresh: onRefreshProjects, onStart: onCreate)
        }
        #if os(macOS)
            // What the Mac's File menu acts on. Published from here because a new thread is the
            // list's business and outlives whichever one is open — see ``ThreadCommands``.
            // ⌘N uses the same agent picker as the compose button.
            .focusedSceneValue(\.threadCommands, ThreadCommands(newThread: newThread))
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

    private func newThread() {
        if let onNewThread { onNewThread() }
        else { choosingAgent = true }
    }

    private func prepareSearchNavigation(_ id: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            searchThreadID = nil
            onSearchSelect?(nil)
            return
        }
        let request = searchRanges(in: messageText(id), term: needle).isEmpty
            ? nil : ThreadSearchRequest(threadId: id, query: needle)
        searchThreadID = request?.threadId
        onSearchSelect?(request)
    }

    @ViewBuilder private func archive(_ threads: [ThreadSummary]) -> some View {
        // DisclosureGroup makes the entire Mac list an outline and indents every thread.
        Button { showArchived.toggle() } label: {
            HStack {
                Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                    .accessibilityHidden(true)
                Label("Archived (\(threads.count))", systemImage: "archivebox")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(showArchived ? "Expanded" : "Collapsed")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        if showArchived { rows(threads) }
    }

    @ViewBuilder private func rows(
        _ threads: [ThreadSummary],
        preview: @escaping (ThreadSummary) -> String? = { _ in nil }
    ) -> some View {
        ForEach(threads) { thread in
            ThreadRow(
                thread: thread,
                working: workingThreads.contains(thread.id),
                preview: preview(thread),
                highlightQuery: searchNeedle,
                selected: selection == thread.id,
                hostLabel: hostLabel(thread.id)
            )
            .tag(thread.id)
            .simultaneousGesture(TapGesture().onEnded { prepareSearchNavigation(thread.id) })
            .accessibilityAction {
                prepareSearchNavigation(thread.id)
                selection = thread.id
            }
            // The plain Mac list already supplies 8 points around its row content.
            .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .contentShape(.rect)
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
        if searchNeedle.isEmpty ? groups.isEmpty : searchResults.isEmpty {
            if searchNeedle.isEmpty {
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
