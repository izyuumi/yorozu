import SwiftUI
import UserNotifications
import YorozuWire

/// The app's sections (owner, 2026-10-14).
enum AppSection: Hashable { case chats, scheduled, settings, search }

/// The one conversation: the Mac's main chat with day separators, a working indicator while it has
/// a turn running, and the composer. The view stays where the user is reading; new messages below
/// raise a "↓ N new" pill, and sending jumps to the bottom.
struct ChatScreen: View {
    @Bindable var model: PhoneModel
    let onRepair: () -> Void

    @State private var section = AppSection.chats
    /// Scheduled's own stack; Chats uses `path`.
    @State private var jobsPath: [ChatRoute] = []
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var details: PhoneModel.Bubble?
    @State private var position = ScrollPosition(edge: .bottom)
    /// The view follows the newest message: an intent only the reader's own scrolling clears. The lazy stack measuring its
    /// rows moves the content under the view by itself, so the view's position alone cannot say whether the reader left.
    @State private var atBottom = true
    @State private var phase = ScrollPhase.idle
    /// The latest scroll geometry, for the settle once the view comes to rest.
    @State private var edge: ScrollEdge?
    @State private var settling: Task<Void, Never>?
    /// The newest message on screen the last time the view was at the bottom: the pill counts past it.
    @State private var seenId: String?
    @State private var path: [ChatRoute] = []
    /// The read cursor the unread divider is drawn from. It follows the Mac's cursor when another
    /// device moves it, and stays put while this one reads, so the divider does not vanish under the reader.
    @State private var unreadAfter: String?
    /// The last message this phone sent as read.
    @State private var sentRead: String?
    @State private var launched = false
    /// The Main chat's first read since it was opened has gone (explicit); reset whenever it closes.
    @State private var mainOpenedRead = false
    @Environment(\.scenePhase) private var scenePhase

    /// How far above the end the view still counts as at the bottom.
    private static let bottomSlack: CGFloat = 24

    var body: some View {
        // The sections (owner, 2026-10-14): a tab bar on iPhone, a sidebar on iPad. The app always opens on Chats.
        TabView(selection: $section) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: AppSection.chats) { chats }
                .badge(model.attentionChats ? Self.dotBadge : nil)
            Tab("Scheduled", systemImage: "clock", value: AppSection.scheduled) {
                NavigationStack(path: $jobsPath) {
                    JobsScreen(model: model) { jobsPath = [.job($0)] }
                        .navigationDestination(for: ChatRoute.self, destination: destination)
                }
            }
            .badge(model.jobs.contains(where: \.needsAttention) ? Self.dotBadge : nil)
            Tab("Settings", systemImage: "gearshape", value: AppSection.settings) {
                SettingsScreen(model: model, onRepair: onRepair) { openChats([.main]) }
            }
            // The system's search tab (#405): its field and transitions are the platform's.
            Tab(value: AppSection.search, role: .search) {
                NavigationStack { SearchScreen(model: model, onOpen: open) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .defaultAdaptableTabBarPlacement(.sidebar)
        #endif
        .background { shortcuts }
        // The Mac's cursor moved by another device (or first loaded) moves the divider; this phone's own
        // does not, nor does any cursor at or before it, so the divider never lands on messages just read.
        .onChange(of: model.readCursor?.messageId, initial: true) { _, id in
            if !atOrBeforeSentRead(id) { unreadAfter = id }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { unreadAfter = model.readCursor?.messageId }
        }
        .onChange(of: readTarget, initial: true) { _, id in markRead(id) }
        .onChange(of: mainShown, initial: true) { _, shown in model.mainShown = shown; if !shown { mainOpenedRead = false } }
        .onDisappear { model.mainShown = false }
        .task(id: model.pushOpen?.id) { await openPush() }
        // Opening the app starts a new chat (#405), not the last screen; earlier drafts stay in the list.
        .task {
            guard !launched else { return }
            launched = true
            if model.pushOpen == nil { navigate([.newChat(UUID().uuidString.lowercased())]) }
        }
        .sheet(item: $details) { bubble in
            MessageDetails(bubble: bubble, delivery: model.delivery(of: bubble),
                           onResend: { model.resend(bubble.id) }, onDelete: { model.delete(bubble.id) })
        }
        .alert("Couldn’t send", isPresented: Binding(get: { model.attachFailure != nil }, set: { if !$0 { model.attachFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.attachFailure ?? "")
        }
        .environment(model.files)
        // The secretary cites what it recalls as `yorozu://message/<id>` links (owner, 2026-10-13), in every screen.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "yorozu", url.host() == "message", let id = url.pathComponents.last, id != "/" else { return .systemAction }
            openMessage(id)
            return .handled
        })
        .yorozuTint()
    }

    /// A small dot on a section, no number (owner, 2026-10-14).
    private static let dotBadge = Text(verbatim: " ")

    #if os(iOS)
    private var compact: Bool { sizeClass == .compact }
    #else
    /// A Mac window always has the list beside the chat.
    private let compact = false
    #endif

    /// Chats: the thread list as the stack's root on iPhone; on iPad the list beside the open chat.
    @ViewBuilder private var chats: some View {
        if compact {
            NavigationStack(path: $path) {
                threadList.navigationDestination(for: ChatRoute.self, destination: destination)
            }
        } else {
            NavigationSplitView {
                threadList
            } detail: {
                NavigationStack(path: $path) {
                    ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right")
                        .navigationDestination(for: ChatRoute.self, destination: destination)
                }
            }
        }
    }

    private var threadList: some View {
        ThreadsScreen(model: model) {
            navigate([.newChat(UUID().uuidString.lowercased())])
        } onOpen: { navigate([$0]) }
            .navigationSubtitleIfAvailable(model.shownStatus.label)
    }

    /// Every page a section's stack can push. Chats hide the tab bar on iPhone, so the composer has the bottom edge.
    @ViewBuilder private func destination(_ route: ChatRoute) -> some View {
        Group {
            switch route {
            case .main:
                timeline
            case .job(let id):
                JobScreen(model: model, jobId: id, onMainChat: { openChats([.main]) }, onOpenMessage: openMessage)
            case .topic(let id, let focus):
                TopicScreen(model: model, topicId: id, focus: focus, onMainChat: { openChats([.main]) }, onOpenMessage: openMessage)
            case .newChat(let id):
                TopicScreen(model: model, topicId: id, focus: nil, onMainChat: { openChats([.main]) }, isNew: true, onOpenMessage: openMessage)
            case .archived:
                ArchivedThreadsScreen(model: model) { path.append($0) }
            case .page(let id):
                PageScreen(model: model, messageId: id)
            }
        }
        #if os(iOS)
        .toolbar(compact && route != .archived ? .hidden : .automatic, for: .tabBar)
        #endif
    }

    /// ⌘1 Chats, ⌘2 Scheduled, ⌘F Search and ⌘, Settings, for a keyboard on iPad (owner, 2026-10-14).
    private var shortcuts: some View {
        Group {
            Button("Chats") { section = .chats }.keyboardShortcut("1")
            Button("Scheduled") { section = .scheduled }.keyboardShortcut("2")
            Button("Search") { section = .search }.keyboardShortcut("f")
            Button("Settings") { section = .settings }.keyboardShortcut(",")
        }
        .hidden()
    }

    /// The main chat, a page of Chats.
    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                let byId = Dictionary(model.timeline.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                let firstUnread = firstUnread
                ForEach(rows) { row in
                    VStack(spacing: LayoutMetrics.stack) {
                        if let day = row.day {
                            Text(day)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        if row.id == firstUnread { UnreadDivider() }
                        MessageRow(
                            bubble: row.bubble, header: header(for: row.bubble, in: byId),
                            delivery: model.delivery(of: row.bubble),
                            onShowRequest: { show(row.bubble.replyTo) },
                            onShowDetails: { details = row.bubble },
                            onResend: { model.resend(row.bubble.id) },
                            onDelete: { model.delete(row.bubble.id) },
                            onReply: canReply(row.bubble) ? { model.replyingTo = row.bubble.id } : nil)
                    }
                    .readableRow()
                    .id(row.id)
                }
                if model.routing == true {
                    ThinkingRow().readableRow()
                }
                // The end, as a row: what `scrollToEnd()` scrolls to. It carries the bottom margin (with the stack's
                // spacing above it), so the end it aligns is the content's end.
                Color.clear.frame(height: LayoutMetrics.gutter - LayoutMetrics.stack).id(Self.endId)
            }
            .scrollTargetLayout()
            .padding(.top, LayoutMetrics.gutter)
        }
        .scrollPosition($position)
        // Only the first layout starts at the bottom; later growth leaves the reading position alone.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: ScrollEdge.self) { geometry in
            // `containerSize` is the bounds less the insets and the offset is -top at the top, so the end
            // sits at content - container - top (measured on iOS 26 and 27, with the bars' insets).
            ScrollEdge(offset: geometry.contentOffset.y,
                       maxOffset: geometry.contentSize.height - geometry.containerSize.height - geometry.contentInsets.top)
        } action: { old, new in
            edge = new
            let atEnd = new.offset >= new.maxOffset - Self.bottomSlack
            if [.tracking, .interacting, .decelerating].contains(phase) {
                atBottom = atEnd
            } else if atEnd {
                atBottom = true
            } else if atBottom, phase == .idle, new.offset == old.offset, new.maxOffset != old.maxOffset {
                // Following, and the end moved under a still view (a message, a longer answer, a row measuring
                // taller, the keyboard): stay on the newest message. Only when the view itself did not move: a drag's
                // first frames can arrive before its phase does, and pinning those yanked the drag back. Drift of the
                // view while following is left to the settle at rest.
                scrollToEnd()
            }
            scheduleSettle()
            if atBottom { seenId = model.timeline.last?.id }
        }
        .onScrollPhaseChange { _, new in
            phase = new
            scheduleSettle()
        }
        // Where the reader left the Main chat (#405): kept while reading older messages, cleared at the bottom.
        .onScrollTargetVisibilityChange(idType: String.self) { ids in
            ReadingPositions.set(atBottom ? nil : ids.first { $0 != Self.endId }, chat: ThreadData.mainId)
        }
        .onAppear {
            guard model.pushOpen == nil, let mark = ReadingPositions.get(ThreadData.mainId) else { return }
            Task {
                // A link or a push takes priority; otherwise wait for the message while the history loads.
                while model.historyLoading, !model.timeline.contains(where: { $0.id == mark }) { try? await Task.sleep(for: .milliseconds(200)) }
                guard model.pushOpen == nil, model.timeline.contains(where: { $0.id == mark }) else { return }
                try? await Task.sleep(for: .milliseconds(100))
                position.scrollTo(id: mark, anchor: .top)
                // After the jump: the end the first layout started at must not pull the view back (the settle follows only a follower).
                atBottom = false
            }
        }
        .onChange(of: model.timeline.last?.id) { _, _ in
            guard let last = model.timeline.last else { return }
            if atBottom {
                scrollToEnd()
                seenId = last.id
            }
        }
        .overlay {
            if model.timeline.isEmpty && model.working != true {
                EmptyChat { model.draft = $0 }
            }
        }
        .overlay(alignment: .bottom) {
            // Whenever the view is away from the end: "↓ N new" with messages below, else "Scroll to bottom".
            VStack {
                if !atBottom {
                    NewMessagesPill(count: newCount) {
                        atBottom = true
                        seenId = model.timeline.last?.id
                        withAnimation { scrollToEnd() }
                    }
                    .padding(.bottom, LayoutMetrics.inner)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Scoped to the pill: on the scroll view it animated every programmatic scroll, which then fought the
            // settle back onto the end.
            .animation(.snappy, value: atBottom)
        }
        // The link's state and the Mac's work float over the timeline as toasts rather than strips that take its
        // space: they come and go often, and the messages must not move when they do.
        .overlay(alignment: .top) {
            VStack(spacing: LayoutMetrics.inner) {
                // Words as well as the dot, so the state is never told by colour alone.
                if model.shownStatus != .connected {
                    // Off the link the Mac's work state is unknown, never idle.
                    Toast { Text(model.updateRequired ?? String(localized: "\(model.shownStatus.label) · Status unknown")) }
                } else if let reason = model.readinessReason {
                    // The Mac's own readiness; when blocked the composer below is off with it.
                    Toast {
                        Label { Text("\(reason) · Fix this on the host") } icon: {
                            Image(systemName: model.readiness?.state == .blocked ? "xmark.octagon" : "exclamationmark.triangle")
                                .foregroundStyle(model.readiness?.state == .blocked ? YorozuPalette.vermilion : YorozuPalette.warning)
                        }
                    }
                }
                if model.working == true {
                    Toast {
                        Label { Text("Working…") } icon: { ProgressView().controlSize(.small) }
                    }
                }
            }
            .padding(.top, LayoutMetrics.inner)
            .padding(.horizontal, LayoutMetrics.gutter)
            .allowsHitTesting(false)
            .animation(.default, value: model.shownStatus)
            .animation(.default, value: model.readinessReason)
            .animation(.default, value: model.working)
        }
        .yorozuBottomBar {
            VStack(spacing: 0) {
                if model.mainChat == false {
                    // Off (#405): its history stays readable; new messages go in chats. The draft here is kept.
                    Text("The Main chat is off. Its history stays here; turn it on in Settings to write in it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, LayoutMetrics.gutter)
                }
                Composer(text: $model.draft, files: $model.draftFiles, attachments: model.attachmentsSupported != false,
                         working: model.working == true, enabled: model.canSend && model.mainChat != false,
                         replyQuote: replyQuote, onCancelReply: { model.replyingTo = nil }) {
                    // Sending jumps to the bottom, so the sent message and its answer are followed.
                    atBottom = true
                    scrollToEnd()
                    model.send()
                } onSendAsTextFile: {
                    atBottom = true
                    scrollToEnd()
                    model.sendAsTextFile()
                }
            }
        }
        .navigationTitle("Main chat")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitleIfAvailable(model.shownStatus.label)
        .toolbar {
            if !Self.hasSubtitle {
                ToolbarItem(placement: .topBarLeading) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: Self.dot))
                        .foregroundStyle(dotColor)
                        .accessibilityElement()
                        .accessibilityLabel(model.shownStatus.label)
                }
            }
        }
    }

    private static let dot: CGFloat = 8

    private var dotColor: Color {
        switch model.shownStatus {
        case .connected: YorozuPalette.sage
        case .hostOffline: YorozuPalette.warning
        case .failed: YorozuPalette.vermilion
        case .connecting, .offline: Color.secondary
        }
    }

    /// Messages below the last one seen at the bottom.
    private var newCount: Int {
        guard let seenId, let index = model.timeline.lastIndex(where: { $0.id == seenId }) else { return 0 }
        return model.timeline.count - 1 - index
    }

    /// Each message, with a day separator before the first message of each day.
    private var rows: [TimelineRow] {
        var previous: Date?
        return model.timeline.map { bubble in
            let date = MessageTime.date(bubble.ts)
            defer { previous = date }
            let newDay = previous.map { !Calendar.current.isDate($0, inSameDayAs: date) } ?? true
            return TimelineRow(bubble: bubble, day: newDay ? MessageTime.day.string(from: date) : nil)
        }
    }

    /// The reply header of an answer: the request when the phone holds it, else the topic's label (a job result
    /// replies to its run trigger, which the Mac never sends). Old results that still carry the stored
    /// `Regarding “…”:` prefix are shown as stored, without a header.
    private func header(for bubble: PhoneModel.Bubble, in byId: [String: PhoneModel.Bubble]) -> ReplyHeader? {
        // The user's own reply: the message it answers, when held.
        if bubble.user {
            return bubble.replyTo.flatMap { byId[$0] }.map { ReplyHeader(text: Self.firstLine($0), revealable: true) }
        }
        let stored = bubble.text.hasPrefix("Regarding “") && bubble.text.contains("”:\n\n")
        // An acknowledgment bubble sits right under the request; quoting it there (and on every milestone) is noise.
        guard RowStyle(bubble) == .answer, bubble.kind != "acknowledgment", !stored, let id = bubble.replyTo else { return nil }
        if let request = byId[id] { return ReplyHeader(text: request.shownText, revealable: true) }
        return bubble.topicId.flatMap { model.topics[$0]?.label }.map { ReplyHeader(text: $0, revealable: false) }
    }

    /// The user's own messages and the agent's answers and questions, once the host has stored them (so it holds the
    /// target); not notices or failures.
    private func canReply(_ bubble: PhoneModel.Bubble) -> Bool {
        bubble.seq != nil && [.user, .answer, .question].contains(RowStyle(bubble))
    }

    /// The composer's quote bar: the first line of the message being replied to.
    private var replyQuote: String? {
        guard let id = model.replyingTo, let target = model.timeline.first(where: { $0.id == id }) else { return nil }
        return Self.firstLine(target)
    }

    /// A quoted message's first non-empty line, its Markdown markers dropped.
    private static func firstLine(_ bubble: PhoneModel.Bubble) -> String {
        let line = bubble.shownText.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        return (try? AttributedString(markdown: line)).map { String($0.characters) } ?? line
    }

    /// Moves to `route` with the keyboard down first. A field still first responder when its screen is covered is
    /// remembered by UIKit and raised again when the screen comes back, which popped the keyboard up on return.
    private func navigate(_ route: [ChatRoute]) {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        path = route
    }

    /// Chats at `route` from any section: a push tap, a citation or a search hit resets Chats to list → target (owner, 2026-10-14).
    private func openChats(_ route: [ChatRoute]) {
        section = .chats
        navigate(route)
    }

    /// At rest, back onto the end when the view is past it, over empty space (content shrank: a status row going away, a
    /// lazy row measuring shorter, the keyboard or composer getting smaller), or short of it while following. Never
    /// mid-gesture, so a bounce at the bottom is not fought.
    private func settle() {
        guard phase == .idle, let edge else { return }
        if edge.offset > edge.maxOffset + 1 || atBottom && edge.offset < edge.maxOffset - 1 { scrollToEnd() }
    }

    /// Once the geometry has held still for a moment: the keyboard and the composer move the insets in animations the
    /// scroll phase does not report, and correcting every frame of one fought it.
    private func scheduleSettle() {
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { settle() }
        }
    }

    /// To the end row. `scrollTo(edge: .bottom)` ignores the keyboard's inset and landed a keyboard height past the end
    /// whenever the keyboard was up, over empty space, and `scrollTo(y:)` counts from another origin (both measured on
    /// iOS 27). Content that grows after this call (the message just sent) moves the end, and the geometry action follows.
    private func scrollToEnd() {
        position.scrollTo(id: Self.endId, anchor: .bottom)
    }

    private static let endId = "end"

    private func show(_ id: String?) {
        guard let id else { return }
        withAnimation { position.scrollTo(id: id, anchor: .top) }
    }

    private static let hasSubtitle: Bool = {
        if #available(iOS 26, macOS 26, *) { return true } else { return false }
    }()

    /// The first message from Yorozu after the read cursor: the user's own messages are never unread.
    private var firstUnread: String? {
        guard let after = unreadAfter, let index = model.timeline.firstIndex(where: { $0.id == after }) else { return nil }
        return model.timeline[(index + 1)...].first { !$0.user }?.id
    }

    /// The newest stored message, while it is on screen: the app active, the chat shown, the view at the bottom.
    private var readTarget: String? {
        guard scenePhase == .active, section == .chats, path == [.main], details == nil, atBottom, model.state == .paired else { return nil }
        return model.timeline.last { $0.seq != nil }?.id
    }

    /// The main timeline is on screen: pushes show no banner.
    private var mainShown: Bool { scenePhase == .active && section == .chats && path == [.main] && details == nil }

    /// A tapped push: its thread, or the main chat at its message once caught up (up to 10 s), else at the bottom.
    private func openPush() async {
        guard let request = model.pushOpen else { return }
        // The composer's draft and files are already kept; written now, so the target opens over a saved draft (#405).
        model.drafts.save()
        openChats([])
        details = nil
        var id: String?
        if let ref = request.ref {
            let end = ContinuousClock.now + .seconds(10)
            while true {
                id = model.messageId(ref: ref)
                guard id == nil, model.state != .paired || model.catchingUp, ContinuousClock.now < end,
                      (try? await Task.sleep(for: .milliseconds(250))) != nil else { break }
            }
        }
        model.pushOpen = nil
        // A push for a thread's message opens the thread (owner, 2026-10-13).
        if let id, let bubble = model.bubbles.first(where: { $0.id == id }), let thread = bubble.threadId {
            openChats([.topic(thread, focus: focus(bubble))])
        } else if let id {
            showOnMain(id)
        } else {
            openChats([.main])
            atBottom = true
            scrollToEnd()
        }
    }

    /// The main chat at one message: scrolled at once when its page is already shown, else once it has been pushed (a
    /// scroll view that does not exist yet ignores the position).
    private func showOnMain(_ id: String) {
        let pushed = section != .chats || path != [.main]
        openChats([.main])
        atBottom = false
        Task {
            if pushed { try? await Task.sleep(for: .milliseconds(400)) }
            withAnimation { position.scrollTo(id: id, anchor: .center) }
        }
    }

    /// `id` is this phone's last sent read or a message before it, in timeline order.
    private func atOrBeforeSentRead(_ id: String?) -> Bool {
        guard let id, let sentRead else { return false }
        if id == sentRead { return true }
        guard let index = model.timeline.firstIndex(where: { $0.id == id }),
              let sent = model.timeline.firstIndex(where: { $0.id == sentRead }) else { return false }
        return index <= sent
    }

    /// Forward only: never a message at or before the Mac's cursor.
    private func markRead(_ id: String?) {
        guard let id else { return }
        // The first read of an opening of the Main chat is explicit: it clears Mark as Unread at an equal cursor too.
        if !mainOpenedRead {
            mainOpenedRead = true
            sentRead = id
            Task { await model.markRead(id, explicit: true) }
            return
        }
        guard id != sentRead, id != model.readCursor?.messageId else { return }
        if let cursor = model.readCursor?.messageId,
           let held = model.timeline.firstIndex(where: { $0.id == cursor }),
           let new = model.timeline.firstIndex(where: { $0.id == id }), new <= held { return }
        sentRead = id
        Task { await model.markRead(id) }
    }

    /// One message by id (a cited link, a thread's source): its thread opens at it, the main timeline scrolls to it, and
    /// one not held here opens the host's page around it.
    private func openMessage(_ id: String) {
        // The composer's draft and files are already kept; written now, so the target opens over a saved draft (#405).
        model.drafts.save()
        guard let bubble = model.bubbles.first(where: { $0.id == id }) else { openChats([.page(id)]); return }
        if let thread = bubble.threadId {
            openChats([.topic(thread, focus: focus(bubble))])
        } else {
            showOnMain(id)
        }
    }

    /// Where a chat scrolls for a message: the message, or for a result its task card shows instead, that card (opened).
    private func focus(_ bubble: PhoneModel.Bubble) -> String {
        model.hidesInTopic(bubble) ? bubble.taskId ?? bubble.id : bubble.id
    }

    /// A search hit, in Chats (#405): its thread at the message (a result its task card shows: the card), a worker step's
    /// task, or the main timeline at the message. Everything is on the device, so nothing waits for the host.
    private func open(_ hit: PhoneModel.LocalHit) {
        model.drafts.save()
        if let id = hit.messageId {
            guard let bubble = model.bubbles.first(where: { $0.id == id }) else { return openChats([.page(id)]) }
            if let thread = bubble.threadId { return openChats([.topic(thread, focus: focus(bubble))]) }
            if let topic = bubble.topicId, model.topics[topic] != nil, model.hidesInTopic(bubble) {
                return openChats([.topic(topic, focus: focus(bubble))])
            }
            return showOnMain(id)
        }
        if let topic = hit.topicId { openChats([.topic(topic, focus: hit.taskId)]) }
    }
}

/// "Unread": above the first message from Yorozu after the read cursor.
private struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: LayoutMetrics.inner) {
            line
            Text("Unread").font(.caption.weight(.semibold))
            line
        }
        .foregroundStyle(.tint)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle().fill(.tint).frame(height: 1).frame(maxWidth: .infinity).accessibilityHidden(true)
    }
}

/// The secretary is reading a message: a typing-style bubble until it answers or hands the work on.
private struct ThinkingRow: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.weight(.bold))
            .foregroundStyle(.secondary)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers)
            .padding(.horizontal, LayoutMetrics.stack)
            .padding(.vertical, LayoutMetrics.stack)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .accessibilityLabel("Thinking…")
    }
}

private struct TimelineRow: Identifiable {
    let bubble: PhoneModel.Bubble
    /// The day separator drawn above this message, if it starts a day.
    let day: String?
    var id: String { bubble.id }
}

private struct ScrollEdge: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
}

/// A notice floating over the timeline: never in its layout, so it moves no message.
private struct Toast<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, LayoutMetrics.stack)
            .padding(.vertical, LayoutMetrics.inner)
            .yorozuGlass(in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
            .accessibilityElement(children: .combine)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// "↓": back to the bottom. An icon, not words (owner, 2026-10-12); VoiceOver hears how many are new.
private struct NewMessagesPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: controlTarget, height: controlTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .yorozuGlass(in: Circle())
        .accessibilityLabel(count > 0 ? String(localized: "\(count) new") : String(localized: "Scroll to bottom"))
    }
}

/// What Yorozu does, and an example that fills the composer when tapped.
private struct EmptyChat: View {
    let onExample: (String) -> Void

    private var example: String {
        String(localized: "Find three quiet mechanical keyboards under ¥25,000 and pick one.")
    }

    var body: some View {
        ContentUnavailableView {
            Label("Ask Yorozu anything", systemImage: "text.bubble")
        } description: {
            Text("Quick questions are answered right here. Bigger work (research, writing, code) runs on your host in the background, and the result comes back to this chat.")
        } actions: {
            VStack(spacing: LayoutMetrics.stack) {
                Text("For example")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button { onExample(example) } label: {
                    Text(example).multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .foregroundStyle(.primary)
                Text("Yorozu remembers what matters on its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A Connection row that opens `ConnectionSettings`, notifications, the host's readiness, About (versions and links)
/// and Copy diagnostics: the Settings section.
private struct SettingsScreen: View {
    let model: PhoneModel
    let onRepair: () -> Void
    var onOpenMain: () -> Void = {}

    @State private var copied = false
    @State private var notifications: UNAuthorizationStatus?
    @State private var reminder = LocalNotices.reminderMinutes
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    NavigationLink {
                        ConnectionSettings(model: model, onRepair: onRepair) {
                            // Without a host the app goes back to pairing.
                            Task { await model.remove() }
                        }
                    } label: {
                        LabeledContent(model.hostName ?? String(localized: "Host"), value: connectionSummary)
                    }
                }
                // Host-wide (#405): one setting every client shares; the host's value shows, cached offline.
                Section {
                    // The host's value shows; while a change waits for its answer, that value with a spinner.
                    Toggle(isOn: Binding(get: { model.mainChatPending ?? (model.mainChat == true) }, set: { model.setMainChat($0) })) {
                        HStack(spacing: LayoutMetrics.inner) {
                            Text("Main chat")
                            if model.mainChatPending != nil { ProgressView().controlSize(.small).accessibilityLabel("Applying on the host") }
                        }
                        Text("One conversation where the secretary files work into chats across topics. Off: every chat stands on its own. Its history stays either way.")
                    }
                    .disabled(model.state != .paired || model.hostSettingsSupported != true || model.mainChat == nil || model.mainChatPending != nil)
                    if model.mainChat == true {
                        Button("Open Main chat", systemImage: "bubble.left") { onOpenMain() }
                    }
                } header: {
                    Text("Host")
                } footer: {
                    if let error = model.mainChatError { Text(error).foregroundStyle(YorozuPalette.warning) }
                    else if model.state != .paired { Text("Changes need the host connected.") }
                }
                Section {
                    Picker(selection: Binding(get: { LocalNotices.reminderMinutes }, set: { model.setReminder(minutes: $0); reminder = $0 })) {
                        ForEach(LocalNotices.reminderChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? String(localized: "Off") : Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))).tag(minutes)
                        }
                    } label: {
                        Text("Unsent message reminder")
                        Text("A notification when a message hasn't reached your host this long after you sent it.")
                    }
                    .id(reminder)
                }
                Section {
                    LabeledContent("Notifications") { Text(LocalizedStringKey(notificationsName)) }
                    if notifications == .denied {
                        Button("Open Settings") {
                            #if os(iOS)
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                            #else
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                            #endif
                        }
                    }
                }
                // Read again on the way back from the Settings app.
                .task(id: scenePhase) { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
                // The host's own readiness, as synced; the fixes are on the host.
                if let readiness = model.readiness {
                    Section {
                        LabeledContent("Host readiness") {
                            Text(model.readinessReason ?? String(localized: "Ready"))
                        }
                        ForEach(readiness.items.filter { $0.severity != .ok }, id: \.id) { item in
                            Label {
                                Text(item.title)
                            } icon: {
                                Image(systemName: item.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                                    .foregroundStyle(item.severity == .blocking ? YorozuPalette.vermilion : YorozuPalette.warning)
                            }
                        }
                    } footer: {
                        if readiness.state != .ready { Text("Fix this on the host") }
                    }
                }
                Section {
                    LabeledContent("Host version", value: model.macVersion ?? String(localized: "Unknown"))
                    LabeledContent("Version on this device", value: Self.version)
                    Link("Privacy Policy", destination: URL(string: "https://yorozu.yumi.to/privacy/")!)
                    Link("Terms of Use", destination: URL(string: "https://yorozu.yumi.to/terms/")!)
                    Link("Source on GitHub", destination: URL(string: "https://github.com/izyuumi/yorozu")!)
                } header: {
                    Text("About")
                }
                Section {
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy diagnostics"),
                           systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = diagnostics
                        copied = true
                    }
                    .task(id: copied) {
                        guard copied, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                        copied = false
                    }
                } footer: {
                    Text("Versions and connection details only: never messages, keys or tokens.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .yorozuTint()
    }

    /// "Connected · Relay": the status, and the path while there is one.
    private var connectionSummary: String {
        ([model.status.label] + [model.path.map { String(localized: String.LocalizationValue($0.name)) }].compactMap { $0 })
            .joined(separator: " · ")
    }

    #if os(iOS)
    private static var system: String { "iOS: \(UIDevice.current.systemVersion)" }
    #else
    private static var system: String { "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)" }
    #endif

    /// Plain English text for a bug report, whatever the interface language. Only what Settings
    /// shows: no message content, keys (the fingerprint is a prefix of the public key) or tokens.
    private var diagnostics: String {
        let date = { (d: Date) in d.ISO8601Format() }
        return [
            "Yorozu diagnostics \(date(Date()))",
            "Client app: \(Self.version)",
            Self.system,
            "Host app: \(model.macVersion ?? "unknown")",
            "Status: \(model.status)",
            "Relay host: \(model.relayHost ?? "none")",
            "Host key fingerprint: \(model.fingerprint ?? "none")",
            "Paired since: \(model.pairedAt.map(date) ?? "unknown")",
            "Last error: \(model.lastError.map { "\(date($0.at)) \($0.message)" } ?? "none")",
            "Path: \(model.path?.name ?? "not connected")",
            "Direct connection: \(model.directEnabled ? "on" : "off")",
            "Direct candidates: \(model.candidates.isEmpty ? "none" : model.candidates.map(\.label).joined(separator: ", "))",
            "Last direct error: \(model.directReport.lastError ?? "none")",
            "Local Network access: \(model.directReport.localNetworkDenied ? "denied" : "not denied")",
            "Notifications: \(notificationsName)",
            "Push registration: \(model.pushRegistration ?? "pending"); relay \(model.pushOnRelay ? "has the token" : "has not stored the token")",
        ].joined(separator: "\n")
    }

    /// English, as Copy diagnostics writes it; Settings shows it through the string catalog.
    private var notificationsName: String {
        switch notifications {
        case .denied: "Off"
        case .notDetermined: "Not asked yet"
        case nil: "Unknown"
        default: "On"
        }
    }

    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()
}

/// Settings › Connection: the host and this device, the link, the direct path, and Repair and Remove.
private struct ConnectionSettings: View {
    let model: PhoneModel
    let onRepair: () -> Void
    let onRemove: () -> Void

    @State private var removing = false

    var body: some View {
        Form {
            Section("Host") {
                LabeledContent("Name", value: model.hostName ?? String(localized: "Unknown"))
                if let fingerprint = model.fingerprint {
                    LabeledContent("Host key") {
                        Text(fingerprint).monospaced().textSelection(.enabled)
                    }
                }
                if let pairedAt = model.pairedAt {
                    LabeledContent("Paired since") { Text(pairedAt, format: .dateTime.year().month().day()) }
                }
            }
            Section("This device") {
                LabeledContent("Name", value: DeviceModel.name)
            }
            Section("Status") {
                LabeledContent("Status", value: model.status.label)
                LabeledContent("Path") { Text(LocalizedStringKey(model.path?.name ?? "Not connected")) }
                if let relayURL = model.relayURL {
                    LabeledContent("Relay") { Text(relayURL).textSelection(.enabled) }
                }
                if let lastError = model.lastError {
                    VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                        LabeledContent("Last error") { Text(lastError.at, format: .relative(presentation: .named)) }
                        Text(lastError.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("Direct connection (LAN / Tailscale)", isOn: Binding(get: { model.directEnabled }, set: { model.setDirect($0) }))
                if model.directEnabled && model.directReport.localNetworkDenied {
                    Text("Local Network access is off. Turn it on in Settings › Privacy & Security › Local Network.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.directEnabled {
                    LabeledContent("Direct addresses") {
                        Text(model.candidates.isEmpty ? String(localized: "None yet") : model.candidates.map(\.label).joined(separator: "\n"))
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    if let error = model.directReport.lastError {
                        VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                            Text("Last direct error")
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Connects straight to the host on the same Wi-Fi or over Tailscale, and falls back to the relay.")
            }
            Section {
                Button("Repair connection", action: onRepair)
                Button("Remove host", role: .destructive) { removing = true }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove host?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove host", role: .destructive, action: onRemove)
        }
    }
}

extension TransportPath {
    /// English, as Copy diagnostics writes it; Settings shows it through the string catalog.
    var name: String {
        switch self {
        case .relay: "Relay"
        case .directLAN: "Direct · Wi-Fi"
        case .directVPN(let candidate): candidate.isTailscale ? "Direct · Tailscale" : "Direct · VPN"
        }
    }
}

extension DirectCandidate {
    /// `192.168.1.5:8738 LAN`, `[fd7a:115c:a1e0::1]:8738 Tailscale`.
    var label: String {
        let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        return "\(address) \(kind == .lan ? "LAN" : isTailscale ? "Tailscale" : "VPN")"
    }
}
