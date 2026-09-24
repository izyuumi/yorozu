import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// One thread's messages, shared by both apps: the phone pushes it from ``ThreadListView``, the
/// Mac shows it as the detail half of its split view. Either way it has to sit inside a
/// navigation stack, which is what the trace drill-down pushes onto.
public struct ChatView: View {
    public let model: ChatModel
    public let thread: ThreadSummary
    private let onNewThread: (() -> Void)?
    private let onCreate: ((ThreadAgent, String?) -> Void)?
    private let resumeRequest: UUID?
    private let notificationClass: String?
    private let notificationEventRef: String?
    private let lastReadAt: Double?
    private let notificationSyncRevision: Int?
    /// Shown while the runtime is unreachable. The two apps lose it differently: the phone
    /// queues what is typed and sends it when the Mac is back, the Mac's sidecar is simply not
    /// running yet.
    public let offlineNotice: String

    /// Where a pairing code tapped in a message goes; the app sets it, and the default drops
    /// the link. See ``OpenURLAction/chatLinks(onPairingLink:)``.
    @Environment(\.onPairingLink) private var onPairingLink
    @Environment(\.threadSearchRequest) private var threadSearchRequest

    /// Whether geometry currently reaches the newest message. Reader intent is tracked
    /// separately because async row growth can make this false without any manual scroll.
    @State private var atBottom = true
    /// The shortcut stays out of the way until the reader is over one viewport from the end.
    @State private var showJumpToLatest = false
    @State private var scrollPhase = ScrollPhase.idle
    /// Geometry can move away from the bottom because replay arrived or a self-sizing row grew,
    /// not because the reader scrolled. Keep that layout fact separate from the reader's intent.
    @State private var newestScroll = NewestScrollIntent()
    /// Bumped on every send, so the haptic fires per send rather than per keystroke.
    @State private var sends = 0
    /// Id of the reply whose first token just landed, which is the moment worth a tap.
    @State private var replyStarted: String?
    @State private var attachmentTooLarge = false
    @State private var attachmentLoading = false
    @State private var attachmentFailure: String?
    @State private var searchRequestRevision = UUID()
    @State private var pendingExternalSearch = false
    @State private var handledNotificationResume: UUID?
    @State private var suppressedSearchRequest: UUID?
    @State private var supersededNotificationResume: UUID?
    #if os(macOS)
        @FocusState private var composerFocused: Bool
    #endif
    @State private var searching = false
    @State private var choosingAgent = false
    @State private var showingTerminal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    /// Which hit the arrows are on. Reset whenever the term changes.
    @State private var hit = 0
    #if os(iOS)
        @State private var timelineRequest: TimelineRequest?
    #endif

    /// Anchor for "scroll to the end". A zero-height view after the last row rather than the
    /// row itself: scrolling to the last row leaves its bottom edge under the composer.
    private static let bottomAnchor = "yorozu.chat.bottom"

    public init(
        model: ChatModel,
        thread: ThreadSummary,
        resumeRequest: UUID? = nil,
        notificationClass: String? = nil,
        notificationEventRef: String? = nil,
        lastReadAt: Double? = nil,
        notificationSyncRevision: Int? = nil,
        onNewThread: (() -> Void)? = nil,
        onCreate: ((ThreadAgent, String?) -> Void)? = nil,
        offlineNotice: String = "Mac offline — what you send waits on this phone until it's back."
    ) {
        self.model = model
        self.thread = thread
        self.resumeRequest = resumeRequest
        self.notificationClass = notificationClass
        self.notificationEventRef = notificationEventRef
        self.lastReadAt = lastReadAt
        self.notificationSyncRevision = notificationSyncRevision
        self.onNewThread = onNewThread
        self.onCreate = onCreate
        self.offlineNotice = offlineNotice
    }

    private var presentation: ThreadPresentation { ThreadPresentation(thread: thread) }

    private var events: [YorozuEvent] { model.timeline(thread.id).events }

    private var rows: [ChatRow] { model.timeline(thread.id).rows(generating: generating) }

    /// Pending decisions take precedence over progress, on both timeline implementations.
    private var activity: ChatActivity? {
        chatActivity(
            in: rows,
            generating: generating,
            streamingId: streamingId,
            answeredApprovals: model.answered,
            answeredQuestions: model.answeredQuestions
        )
    }

    private var generating: Bool { model.generating.contains(thread.id) }

    /// Every occurrence of the search term in this thread, in reading order.
    private var hits: [SearchHit] { searchHits(in: events, term: search) }

    private var draft: Binding<String> {
        Binding(get: { model.drafts[thread.id] ?? "" }, set: { model.drafts[thread.id] = $0 })
    }

    private var attachments: Binding<[MessageAttachment]> {
        Binding(get: { model.attachments[thread.id] ?? [] }, set: { model.attachments[thread.id] = $0 })
    }

    /// The last message, if it is an agent reply still arriving. A user message sent after a
    /// finished reply starts a turn too, and that reply is not streaming again: it stays Markdown.
    private var streamingId: String? { generating ? streamingMessageId(in: events) : nil }

    /// The timeline's link policy, built here because the phone's rows are hosted in UIKit
    /// cells that do not inherit this view's environment and have to be handed it per row.
    private var linkAction: OpenURLAction { .chatLinks(onPairingLink: onPairingLink) }

    private func newThread() {
        if let onNewThread { onNewThread() }
        else { choosingAgent = true }
    }

    public var body: some View {
        VStack(spacing: 0) {
            UpdateStatusView(status: model.updateStatus) { model.updateControl(.postpone) }
            if !model.ownerOnline && model.updateStatus.phase != .installing {
                Banner(text: offlineNotice, systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            }
            if let failure = model.failure {
                Banner(text: failure, systemImage: "exclamationmark.triangle")
            }
            if thread.interruptedTurnId != nil {
                VStack(alignment: .leading) {
                    Label("Turn interrupted", systemImage: "pause.circle")
                    Text(thread.canResume == false ? "Interrupted before the agent created a session. Dismiss, then send your request again." : "The Mac restarted. Continue when you're ready.").font(.callout)
                    HStack {
                        if thread.canResume != false {
                            Button("Continue") { model.recover(thread, action: .continue) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Dismiss") { model.recover(thread, action: .dismiss) }
                            .buttonStyle(.bordered)
                    }
                    .disabled(!model.ownerOnline)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            }
            if let path = presentation.projectPath {
                projectContext(path)
            }
            Group {
                if rows.isEmpty {
                    EmptyThreadView(presentation: presentation)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Every link in a message is text the model wrote. Only the web and mail
                    // open from here; a pairing code is asked about first, the rest is dropped.
                    messages.environment(\.openURL, linkAction)
                }
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YorozuPalette.canvas.ignoresSafeArea())
        .yorozuTint()
        // A truncated tool result in this thread's trace asks the Mac for the rest through here.
        .environment(\.fetchToolResult) { model.requestToolResult($0, in: thread.id) }
        .sheet(isPresented: $choosingAgent) {
            if let onCreate {
                NewThreadPicker(projects: model.projects, status: model.projectListStatus,
                    onRefresh: { await model.refreshProjects() }, onStart: onCreate)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showingTerminal) {
            TerminalSheet(model: model, thread: thread)
                #if os(iOS)
                .presentationDetents([.medium])
                #else
                .frame(minWidth: 700, minHeight: 450)
                #endif
        }
        .onChange(of: model.state, initial: true) { _, state in
            if state == .paired { model.requestApprovalSettings() }
        }
        .navigationTitle(thread.displayTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #else
            // A thread on a model of its own says so beside its title. Only then — the default
            // is the case that needs no caption. The Mac has a title bar subtitle for exactly
            // this; the phone uses a compact identity in its `.principal` item.
            .navigationSubtitle(macModelCaption)
        #endif
        #if os(iOS)
        .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        AgentMarkView(presentation.agent, size: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(thread.displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(model.ownerOnline ? YorozuPalette.sage : Color.secondary)
                                    .frame(width: 5, height: 5)
                                    .accessibilityHidden(true)
                                Text(presentation.agent.label)
                                    .lineLimit(1)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    // The split-view bar can propose only a few points on Duo's inner display.
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(model.ownerOnline ? String(localized: "Mac online") : String(localized: "Mac offline"))
                }
                if #available(iOS 27.1, *) {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if model.terminalEnabled {
                            Button("Open terminal", systemImage: "terminal") { showingTerminal = true }
                        }
                        Button("Find in thread", systemImage: "magnifyingglass") { searching = true }
                            .keyboardShortcut("f")
                    }
                    if onNewThread != nil || onCreate != nil {
                        // Duo places bottom-bar actions at the lower end of its vertical bar.
                        ToolbarItem(placement: .bottomBar) {
                            Button("New session", systemImage: "square.and.pencil", action: newThread)
                        }
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if model.terminalEnabled {
                            Button("Open terminal", systemImage: "terminal") { showingTerminal = true }
                        }
                        Button("Find in thread", systemImage: "magnifyingglass") { searching = true }
                            .keyboardShortcut("f")
                        if onNewThread != nil || onCreate != nil {
                            Button("New session", systemImage: "square.and.pencil", action: newThread)
                        }
                    }
                }
        }
        #else
        .toolbar {
            if model.terminalEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open terminal", systemImage: "terminal") { showingTerminal = true }
                }
            }
        }
        #endif
        // Opened from the magnifier rather than always on show: a thread is for reading, and
        // a permanent search field would be one more thing to read past — and on iOS 26 it
        // would be one more bar under the composer, which already owns the bottom of a chat.
        .threadSearch(text: $search, presented: $searching)
        .onChange(of: resumeRequest, initial: true) { _, _ in
            handleNotificationResume()
        }
        .onChange(of: threadSearchRequest, initial: true) { _, _ in
            applyThreadSearchRequest()
        }
        // The Mac reuses this detail view while its sidebar selection changes. A new thread is
        // a new opening intent even when the surrounding `ChatView` value keeps its state.
        .onChange(of: thread.id, initial: true) { _, _ in
            atBottom = true
            showJumpToLatest = false
            scrollPhase = .idle
            newestScroll = NewestScrollIntent()
            attachmentLoading = false
            attachmentFailure = nil
            attachmentTooLarge = false
            searching = false
            search = ""
            hit = 0
            pendingExternalSearch = false
            #if os(iOS)
                timelineRequest = nil
            #endif
            applyThreadSearchRequest()
        }
        // A reply being read aloud follows the thread it is in: walking away stops it, which is
        // the same thing every other app that talks does. Leaving a thread is the trigger on
        // both platforms; the view going away is only the phone's, where it means the chat was
        // popped off the stack. On the Mac the chat is a pane in a window that SwiftUI tears
        // down and builds again for reasons of its own, and stopping on that cut a reply off
        // mid-sentence, with nothing on screen having changed.
        // Closing the window is handled where the window is — see ``ChatWindowView``.
        .onChange(of: thread.id) { _, _ in
            Speaker.shared.stop()
        }
        #if os(iOS)
            .onDisappear {
                Speaker.shared.stop()
            }
        #endif
        // Keyed on the thread: the Mac's split view builds its detail more than once while the
        // window and the thread list settle, and a plain `.task` left the seeded state on
        // whichever copy ran first rather than on the one on screen.
        .task(id: thread.id) {
            ChatShowcase.apply(search: $search, searching: $searching)
        }
        // What the Mac's Edit, Thread and Chat menus act on. The same four things the toolbar
        // and the composer offer, published where a menu built by the scene can reach them.
        #if os(macOS)
            .focusedSceneValue(
                \.chatCommands,
                ChatCommands(
                    find: { searching = true },
                    exportTitle: thread.displayTitle,
                    exportMarkdown: { threadMarkdown(thread: thread, events: events) },
                    stop: generating ? { model.interrupt(in: thread.id) } : nil,
                    models: model.models(for: thread),
                    model: thread.model,
                    setModel: { model.setModel(thread, $0) }
                )
            )
        #endif
        // Sending, and the first token of the answer: the two moments the thread changes hands.
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: replyStarted) { _, id in
            id != nil
        }
        .alert("Attachments are too large", isPresented: $attachmentTooLarge) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose up to 10 files, no larger than 5 MB each or 20 MB together.")
        }
    }

    private func handleNotificationResume() {
        guard let resumeRequest, resumeRequest != handledNotificationResume else { return }
        handledNotificationResume = resumeRequest
        supersededNotificationResume = nil
        suppressedSearchRequest = threadSearchRequest?.id
        searching = false
        search = ""
        hit = 0
        pendingExternalSearch = false
        #if os(iOS)
            timelineRequest = nil
        #endif
    }

    private func applyThreadSearchRequest() {
        // A notification chooses a concrete event. Ignore the older list search request, but
        // allow a later explicit search (a new request id) in the same open conversation.
        handleNotificationResume()
        guard let request = threadSearchRequest, request.threadId == thread.id,
              request.id != suppressedSearchRequest else { return }
        // The notification target may still be waiting for sync. A newer explicit search
        // supersedes that pending target as well as any already-rendered notification jump.
        supersededNotificationResume = resumeRequest
        searching = true
        search = request.query
        hit = 0
        pendingExternalSearch = true
        // A reused Mac detail can return to the same request after another selection.
        searchRequestRevision = UUID()
    }

    private var modelBinding: Binding<String?> {
        Binding(get: { thread.model }, set: { model.setModel(thread, $0) })
    }

    private var effortBinding: Binding<ReasoningEffort?> {
        Binding(get: { thread.effort }, set: { model.setEffort(thread, $0) })
    }

    /// Compact Quiet keeps the active runtime visible beside every Mac thread title. A default
    /// thread is still running on a concrete first model; hiding that identity made the shipped
    /// toolbar materially different from the design and forced a menu open to discover it.
    private var macModelCaption: String {
        if thread.agent?.needsFolder == true && thread.model == nil { return "Auto" }
        let spec = thread.model ?? model.models(for: thread).first?.id
        guard let spec, !spec.isEmpty else { return "" }
        if let option = model.models(for: thread).first(where: { $0.id == spec }) {
            return option.menuLabel
        }
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let provider = parts[0] == "anthropic" ? "Claude" : parts[0].capitalized
            return "\(provider) · \(parts[1])"
        }
        return spec
    }

    @ViewBuilder private var messages: some View {
        #if os(iOS)
            nativeMessages
        #else
            // The split-view detail is reused across selections. Recreate the scroll container
            // so its default bottom anchor belongs to this thread, not the previous one.
            swiftUIMessages.id(thread.id)
        #endif
    }

    #if os(iOS)
        private var nativeMessages: some View {
            let notificationRequest = resumeRequest.flatMap { id -> TimelineRequest? in
                guard id != supersededNotificationResume else { return nil }
                // A cold notification can resolve its thread before that thread's refreshed
                // events arrive. Keep the request pending until the unread assistant bubble
                // exists; turning a missing target into `.latest` here consumed the request
                // against stale cached rows and never corrected the position afterwards.
                if let target = resumeRowId(
                    rows: rows,
                    lastReadAt: lastReadAt,
                    notificationClass: notificationClass,
                    notificationEventRef: notificationEventRef
                ) {
                    return TimelineRequest(id: id, target: .event(target))
                }
                guard notificationRefreshFinished(
                    initialRevision: notificationSyncRevision,
                    currentRevision: model.syncRevision
                ) else { return nil }
                return TimelineRequest(id: id, target: .latest)
            }
            return IOSChatTimeline(
                rows: rows,
                activity: activity,
                agent: presentation.agent,
                request: timelineRequest,
                notificationRequest: notificationRequest,
                presentation: TimelinePresentation(
                    search: search,
                    outbox: model.outbox,
                    answered: model.answered,
                    answeredQuestions: model.answeredQuestions,
                    questionChoices: model.questionChoices,
                    handledProposals: model.handledProposals,
                    choices: model.choices
                ),
                atBottom: $atBottom,
                showJumpToLatest: $showJumpToLatest,
                content: { row in
                    AnyView(
                        rowView(row)
                            .environment(\.searchHighlight, search)
                            .environment(\.openURL, linkAction)
                    )
                }
            )
            // A thread change must create a fresh native timeline. Reusing the previous
            // coordinator preserves its old scroll position instead of opening at the newest
            // message.
            .id(thread.id)
            .onChange(of: ChangeStamp(events: events)) { _, _ in noteReplyStart() }
            .overlay(alignment: .bottom) {
                if showJumpToLatest, search.isEmpty {
                    ScrollToBottomPill {
                        timelineRequest = TimelineRequest(target: .latest)
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: showJumpToLatest)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !search.isEmpty {
                    SearchHitBar(index: hit, total: hits.count) { step in
                        guard !hits.isEmpty else { return }
                        hit = (hit + step + hits.count) % hits.count
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: search) { _, _ in
                hit = 0
                requestCurrentHit()
            }
            .onChange(of: hit) { _, _ in requestCurrentHit() }
            .onChange(of: searchRequestRevision) { _, _ in requestCurrentHit() }
            .onChange(of: hits, initial: true) { _, _ in
                if pendingExternalSearch { requestCurrentHit() }
            }
            .animation(reduceMotion ? nil : .snappy, value: search.isEmpty)
        }

        private func requestCurrentHit() {
            guard hits.indices.contains(hit) else { return }
            pendingExternalSearch = false
            timelineRequest = TimelineRequest(target: .event(hits[hit].eventId))
        }
    #endif

    private var swiftUIMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // A delegation collapses to one card where it started and what the
                    // specialist did is behind it; the main agent's own tool use is shown
                    // here, grouped, where it happened.
                    ForEach(rows) { row in rowView(row) }
                    if let activity { ChatActivityRow(activity: activity, agent: presentation.agent) }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .compactQuietTranscriptLayout()
                // Handed down rather than threaded through every bubble, block and table cell
                // between the field and the run of text a hit is inside.
                .environment(\.searchHighlight, search)
            }
            // A thread opens on its newest message, like every other chat: the anchor does it
            // during layout, so there is no jump from the top to watch on the way in.
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // `visibleRect` is in content coordinates, which is what makes this reliable:
                // a thread shorter than the screen sits under a content inset and reports a
                // negative `contentOffset`, so measuring from the offset calls a fully visible
                // thread "scrolled up". A little slack, so resting a few points short of the
                // end still counts as being at the end and keeps following the reply.
                geometry.visibleRect.maxY >= geometry.contentSize.height - 40
            } action: { _, isAtBottom in
                atBottom = isAtBottom
                newestScroll.observe(atBottom: isAtBottom, phase: scrollPhase)
            }
            // Rows can gain height after their first layout (sync replay, streaming Markdown,
            // images and link previews). Keep the newest edge pinned while that is still what
            // the reader asked to see; `atBottom` alone cannot distinguish growth from a drag.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { oldHeight, newHeight in
                guard oldHeight != newHeight,
                      newestScroll.shouldPinLatest(during: scrollPhase)
                else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                showsJumpToLatest(
                    contentHeight: geometry.contentSize.height,
                    visibleBottom: geometry.visibleRect.maxY,
                    viewportHeight: geometry.visibleRect.height
                )
            } action: { _, show in
                showJumpToLatest = show
            }
            // Every frame of a streaming reply lands here, not just every message: the text of
            // the last event grows in place, so its id alone would never change.
            .onChange(of: ChangeStamp(events: events)) { _, _ in
                noteReplyStart()
                guard newestScroll.shouldPinLatest(during: scrollPhase) else { return }
                // Streaming frames arrive faster than a scroll animation can finish. Starting
                // another animation for each one makes the viewport repeatedly retarget and
                // visibly hitch; following the growing edge needs no transition.
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
                newestScroll.observe(atBottom: atBottom, phase: phase)
            }
            .overlay(alignment: .bottom) {
                // Not while searching: the arrows are already moving the thread about, and a
                // pill offering to jump somewhere else would be arguing with them.
                if showJumpToLatest, search.isEmpty {
                    ScrollToBottomPill {
                        newestScroll.followLatest()
                        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: showJumpToLatest)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !search.isEmpty {
                    SearchHitBar(index: hit, total: hits.count) { step in
                        guard !hits.isEmpty else { return }
                        hit = (hit + step + hits.count) % hits.count
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // A new term starts at its first hit; stepping moves to the next. Both end up here.
            .onChange(of: search) { _, _ in
                hit = 0
                scrollToHit(proxy)
            }
            .onChange(of: hit) { _, _ in scrollToHit(proxy) }
            .onChange(of: searchRequestRevision) { _, _ in scrollToHit(proxy) }
            .onChange(of: hits, initial: true) { _, _ in
                if pendingExternalSearch { scrollToHit(proxy) }
            }
            .animation(reduceMotion ? nil : .snappy, value: search.isEmpty)
        }
    }

    @ViewBuilder private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .work(let work):
            WorkRowView(work: work).id(work.id)
        case .message(let event):
            if case .message(let data) = event.payload {
                MessageBubble(
                    id: event.id,
                    data: data,
                    streaming: event.id == streamingId,
                    status: model.outboxStatus(of: event.id),
                    onRetry: data.role == .user ? { retry(data) } : nil,
                    onDelete: { model.delete(event.id, in: thread.id) },
                    onResend: { model.retry(event.id) },
                    agent: presentation.agent
                )
                .id(event.id)
            }
        case .approval(let event):
            if case .approvalCard(let card) = event.payload {
                ApprovalCardView(
                    card: card,
                    answered: model.answered.contains(card.actionId),
                    chosen: model.choices[card.actionId]
                ) { choice, rule in
                    model.answer(card.actionId, in: thread.id, choice, rule: rule)
                }
                .id(event.id)
            }
        case .proposal(let event):
            if case .ruleProposal(let proposal) = event.payload {
                RuleProposalCardView(
                    proposal: proposal,
                    handled: model.handledProposals.contains(proposal.proposalId),
                    onSave: { model.saveRule($0, proposalId: proposal.proposalId) },
                    onDismiss: { model.dismissProposal(proposal.proposalId) }
                )
                .id(event.id)
            }
        case .question(let event):
            if case .questionCard(let card) = event.payload {
                QuestionCardView(
                    card: card,
                    answered: model.answeredQuestions.contains(card.questionId),
                    chosen: model.questionChoices[card.questionId]
                ) { model.answerQuestion(card.questionId, in: thread.id, $0) }
                .id(event.id)
            }
        }
    }

    /// Puts the current hit in the middle of the screen, where a hit being read wants to be.
    private func scrollToHit(_ proxy: ScrollViewProxy) {
        guard hits.indices.contains(hit) else { return }
        pendingExternalSearch = false
        newestScroll.targetEvent()
        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(hits[hit].eventId, anchor: .center) }
    }

    private func projectContext(_ path: String) -> some View {
        Label {
            Text(path)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "folder")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Project folder: \(path)"))
        #if os(macOS)
            .help(path)
        #endif
    }

    private var composer: some View {
        // One surface, like Messages: the attach button, the field, the staged file and the
        // send control all live inside the same rounded container, so the eye reads one thing
        // to type into rather than three controls in a row.
        VStack(alignment: .leading, spacing: 0) {
            if let attachmentFailure {
                HStack(alignment: .top, spacing: 8) {
                    Label(attachmentFailure, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.attachmentFailure = nil
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: controlTarget, height: controlTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss attachment error")
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.top, 8)
            }
            if attachmentLoading {
                Label("Loading attachments…", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            if !attachments.wrappedValue.isEmpty {
                StagedStrip(attachments: attachments.wrappedValue) { index in
                    attachments.wrappedValue.remove(at: index)
                }
                .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            #if os(iOS)
                ComposerTextView(
                    text: draft,
                    placeholder: presentation.composerPlaceholder,
                    onSubmit: send,
                    onPasteImage: generating ? nil : { pasteImages() }
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)

                HStack(alignment: .center, spacing: 4) {
                    attachButton
                    runSettingsButton
                    Spacer(minLength: 4)
                    if generating {
                        stopButton
                    }
                    sendButton
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            #else
                // Give writing its own row: model names and a running turn's Stop control
                // must never reduce the space available for the message itself.
                TextField(presentation.composerPlaceholder, text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit { draft.wrappedValue += "\n" }
                    .focused($composerFocused)
                    .background(ImagePasteMonitor(isActive: composerFocused && !generating, onPaste: pasteImages))
                    .accessibilityLabel(presentation.composerPlaceholder)

                HStack(alignment: .center, spacing: 4) {
                    attachButton
                    runSettingsButton
                        .frame(maxWidth: 280, alignment: .leading)
                    Spacer(minLength: 4)
                    if generating {
                        stopButton
                    }
                    sendButton
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            #endif
        }
        .background(fieldBackground, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
                .strokeBorder(
                    generating ? YorozuPalette.vermilion.opacity(0.72) : YorozuPalette.rule.opacity(0.82),
                    lineWidth: generating ? 1.5 : 0.8
                )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .compactQuietComposerLayout()
    }

    private var attachButton: some View {
        AttachButton(
            remaining: MessageAttachment.maxCount - attachments.wrappedValue.count,
            onPick: addAttachments,
            onTooLarge: { attachmentTooLarge = true },
            onLoadingChanged: { loading in
                if loading { attachmentFailure = nil }
                attachmentLoading = loading
            }
        )
        .id(thread.id)
        .disabled(generating)
    }

    private func pasteImages() {
        guard !attachmentLoading else {
            reportAttachmentFailure(String(localized: "Wait for attachments to finish loading, then paste again."))
            return
        }
        attachmentFailure = nil
        stageAttachments(
            pasteboardImagePicks(),
            remaining: MessageAttachment.maxCount - attachments.wrappedValue.count,
            onPick: addAttachments,
            onTooLarge: { attachmentTooLarge = true },
            onFailure: reportAttachmentFailure
        )
    }

    private func reportAttachmentFailure(_ message: String) {
        if let previous = attachmentFailure {
            if !previous.contains(message) { attachmentFailure = previous + "\n" + message }
        } else {
            attachmentFailure = message
        }
    }

    private func addAttachments(_ picked: [MessageAttachment]) {
        let result = addingAttachments(picked, to: attachments.wrappedValue)
        attachments.wrappedValue = result.attachments
        if result.rejectedCount > 0 {
            reportAttachmentFailure(String(localized: "Some attachments couldn’t be added. A message can contain up to 10 attachments and 20 MB in total."))
        }
    }

    private var runSettingsButton: some View {
        Menu {
            #if os(macOS)
                Text("Current model: \(composerModelLabel)")
                Text("Effort: \(thread.effort?.label ?? String(localized: "Default"))")
                Divider()
            #endif

            Picker("Model", selection: modelBinding) {
                Text("Auto").tag(String?.none)
                ForEach(model.models(for: thread)) { option in
                    Text(option.menuLabel).tag(Optional(option.id))
                }
            }
            Picker("Effort", selection: effortBinding) {
                Text("Default").tag(ReasoningEffort?.none)
                ForEach(model.efforts(for: thread)) { effort in
                    Text(effort.label).tag(Optional(effort))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(composerChipLabel).font(.subheadline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: controlTarget)
        }
        .menuStyle(.borderlessButton)
        #if os(macOS)
            .menuIndicator(.hidden)
            .help(composerChipLabel)
        #endif
        .accessibilityIdentifier("runSettingsMenu")
        .accessibilityLabel("Model and effort")
        .accessibilityValue("\(composerModelLabel), \(thread.effort?.label ?? "Default effort")")
    }

    private var composerModelLabel: String {
        guard let spec = thread.model else { return "Auto" }
        return model.models(for: thread).first(where: { $0.id == spec })?.label ?? spec
    }

    private var composerChipLabel: String {
        guard let effort = thread.effort else { return composerModelLabel }
        return "\(composerModelLabel) · \(effort.label)"
    }


    private var fieldBackground: Color { YorozuPalette.paper }

    /// Stop stays beside the composer while a turn runs. Send never changes jobs: another
    /// message steers that active turn, which is why replacing it with Stop made steering
    /// impossible from the app.
    private var stopButton: some View {
        Button {
            model.interrupt(in: thread.id)
        } label: {
            Image(systemName: "stop.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.background)
                .frame(width: sendCircle, height: sendCircle)
                .background(Color.primary, in: Circle())
        }
        .buttonStyle(.plain)
        .frame(width: controlTarget, height: controlTarget)
        .contentShape(Rectangle())
        .hoverHighlight()
        // Esc stops on both platforms: unlike Return, nothing else in the composer claims it.
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel("Stop")
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.body.weight(.bold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .frame(width: sendCircle, height: sendCircle)
                .background(canSend ? YorozuPalette.vermilion : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: canSend ? 0 : 1.5))
        }
        .buttonStyle(.plain)
        .frame(width: controlTarget, height: controlTarget)
        .hoverHighlight()
        .disabled(!canSend)
        .macKey(.return)
        .accessibilityLabel("Send")
    }

    private var canSend: Bool {
        !attachmentLoading && (
            !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.wrappedValue.isEmpty
        )
    }

    private func send() {
        guard canSend else { return }
        model.send(in: thread)
        sends += 1
        // Sending is always a jump to the end: it is your own message, and you meant it.
        atBottom = true
        newestScroll.followLatest()
    }

    /// Sends the same thing again, as a new message. The original stays where it is — a
    /// transcript that quietly rewrote itself would not be one.
    private func retry(_ data: MessageData) {
        model.send(data.text, in: thread.id, attachments: data.attachments)
        sends += 1
        atBottom = true
        newestScroll.followLatest()
    }

    /// Fires the reply haptic once per reply, on the event that first carries agent text.
    private func noteReplyStart() {
        guard let streamingId else { return }
        if replyStarted != streamingId { replyStarted = streamingId }
    }
}

#if os(iOS)
    private struct TimelineRequest: Equatable {
        enum Target: Equatable { case latest, event(String) }
        let id: UUID
        let target: Target

        init(id: UUID = UUID(), target: Target) {
            self.id = id
            self.target = target
        }
    }

    /// State that changes a row without changing its event. Keeping it separate lets streaming
    /// reconfigure only the growing reply while search, queue and card actions refresh all
    /// visible hosted rows when their presentation really changed.
    private struct TimelinePresentation: Equatable {
        let search: String
        let outbox: [OutboxItem]
        let answered: Set<String>
        let answeredQuestions: Set<String>
        let questionChoices: [String: String]
        let handledProposals: Set<String>
        let choices: [String: ApprovalAnswerData.Answer]
    }

    /// Reports every UIKit layout pass. A diffable snapshot can finish before hosted SwiftUI
    /// cells publish their final self-sized heights, so snapshot completion alone is not a safe
    /// "initial scroll finished" boundary.
    private final class TimelineCollectionView: UICollectionView {
        var didLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            didLayout?()
        }
    }

    /// Signal-style native timeline for iOS. Diffable updates touch only changed visible rows;
    /// UIKit owns gesture arbitration and scroll continuity instead of rebuilding one SwiftUI
    /// scroll tree as a reply grows.
    private struct IOSChatTimeline: UIViewRepresentable {
        let rows: [ChatRow]
        let activity: ChatActivity?
        let agent: ThreadAgent
        let request: TimelineRequest?
        let notificationRequest: TimelineRequest?
        let presentation: TimelinePresentation
        @Binding var atBottom: Bool
        @Binding var showJumpToLatest: Bool
        let content: (ChatRow) -> AnyView

        private enum Entry: Hashable {
            case row(String)
            case activity(ChatActivity)
        }

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UICollectionView {
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            let collectionView = TimelineCollectionView(
                frame: .zero,
                collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
            )
            collectionView.backgroundColor = .clear
            collectionView.alwaysBounceVertical = true
            collectionView.keyboardDismissMode = .interactive
            collectionView.delegate = context.coordinator
            context.coordinator.install(on: collectionView)
            return collectionView
        }

        func updateUIView(_ collectionView: UICollectionView, context: Context) {
            context.coordinator.parent = self
            context.coordinator.update(collectionView)
        }

        @MainActor final class Coordinator: NSObject, UICollectionViewDelegate {
            var parent: IOSChatTimeline
            private var dataSource: UICollectionViewDiffableDataSource<Int, Entry>?
            private var rowsById: [String: ChatRow] = [:]
            private var previousRows: [String: ChatRow] = [:]
            private var previousPresentation: TimelinePresentation?
            private var lastRequest: UUID?
            private var lastNotificationRequest: TimelineRequest?
            private var newestScroll = NewestScrollIntent()
            private var animatingToLatest = false
            private var animatingToEvent = false

            init(_ parent: IOSChatTimeline) { self.parent = parent }

            func install(on collectionView: UICollectionView) {
                let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Entry> {
                    [weak self] cell, _, entry in
                    guard let self else { return }
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    cell.contentConfiguration = UIHostingConfiguration {
                        switch entry {
                        case .row(let id):
                            if let row = self.rowsById[id] {
                                self.parent.content(row).compactQuietTranscriptLayout()
                            }
                        case .activity(let activity):
                            ChatActivityRow(activity: activity, agent: self.parent.agent).compactQuietTranscriptLayout()
                        }
                    }
                    .margins(.horizontal, 10)
                    .margins(.vertical, 3)
                }
                dataSource = UICollectionViewDiffableDataSource<Int, Entry>(collectionView: collectionView) {
                    collectionView, indexPath, entry in
                    collectionView.dequeueConfiguredReusableCell(
                        using: registration,
                        for: indexPath,
                        item: entry
                    )
                }
                if let timeline = collectionView as? TimelineCollectionView {
                    timeline.didLayout = { [weak self, weak timeline] in
                        guard let self, let timeline else { return }
                        self.pinLatestIfNeeded(timeline)
                        Task { @MainActor [weak self, weak timeline] in
                            guard let self, let timeline else { return }
                            self.reportBottom(timeline)
                        }
                    }
                }
            }

            func update(_ collectionView: UICollectionView) {
                rowsById = Dictionary(parent.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                var entries = parent.rows.map { Entry.row($0.id) }
                if let activity = parent.activity { entries.append(.activity(activity)) }

                var changed = parent.rows.compactMap { previousRows[$0.id] == $0 ? nil : Entry.row($0.id) }
                if previousPresentation != parent.presentation { changed = entries }
                previousRows = rowsById
                previousPresentation = parent.presentation

                let previousEntries = dataSource?.snapshot().itemIdentifiers ?? []
                guard !changed.isEmpty || entries != previousEntries else {
                    applyRequest(collectionView)
                    return
                }
                var snapshot = NSDiffableDataSourceSnapshot<Int, Entry>()
                snapshot.appendSections([0])
                snapshot.appendItems(entries)
                let existing = Set(previousEntries)
                snapshot.reconfigureItems(changed.filter { existing.contains($0) })
                dataSource?.apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    collectionView.layoutIfNeeded()
                    self.pinLatestIfNeeded(collectionView)
                    self.applyRequest(collectionView)
                    self.reportBottom(collectionView)
                }
            }

            private func applyRequest(_ collectionView: UICollectionView) {
                let request: TimelineRequest
                if let notification = parent.notificationRequest,
                   notification != lastNotificationRequest {
                    lastNotificationRequest = notification
                    // A notification wins if it arrives in the same update as an old search or
                    // latest request. Mark that request consumed so it cannot pull the view away
                    // again on the next render.
                    lastRequest = parent.request?.id
                    request = notification
                } else {
                    guard let ordinary = parent.request, ordinary.id != lastRequest else { return }
                    lastRequest = ordinary.id
                    request = ordinary
                }
                switch request.target {
                case .latest:
                    newestScroll.followLatest()
                    animatingToEvent = false
                    scrollToLatest(collectionView, animated: !UIAccessibility.isReduceMotionEnabled)
                case .event(let id):
                    guard let index = dataSource?.snapshot().indexOfItem(.row(id)) else { return }
                    let animated = !UIAccessibility.isReduceMotionEnabled
                    newestScroll.targetEvent()
                    animatingToLatest = false
                    animatingToEvent = animated
                    collectionView.scrollToItem(
                        at: IndexPath(item: index, section: 0),
                        at: .centeredVertically,
                        animated: animated
                    )
                    if !animated { animatingToEvent = false }
                }
            }

            private func scrollToLatest(_ collectionView: UICollectionView, animated: Bool) {
                let count = collectionView.numberOfItems(inSection: 0)
                guard count > 0 else { return }
                animatingToLatest = animated && !isAtBottom(collectionView)
                collectionView.scrollToItem(
                    at: IndexPath(item: count - 1, section: 0),
                    at: .bottom,
                    animated: animated
                )
            }

            private func pinLatestIfNeeded(_ collectionView: UICollectionView) {
                let phase: ScrollPhase = collectionView.isTracking || collectionView.isDragging
                    ? .interacting
                    : collectionView.isDecelerating ? .decelerating
                    : animatingToLatest ? .animating : .idle
                guard !animatingToLatest, !animatingToEvent,
                      newestScroll.shouldPinLatest(during: phase),
                      !isAtBottom(collectionView)
                else { return }
                scrollToLatest(collectionView, animated: false)
            }

            private func isAtBottom(_ scrollView: UIScrollView) -> Bool {
                scrollView.contentOffset.y + scrollView.adjustedContentInset.top
                    + scrollView.bounds.height >= scrollView.contentSize.height - 40
            }

            private func reportBottom(_ scrollView: UIScrollView) {
                let value = isAtBottom(scrollView)
                let phase: ScrollPhase = scrollView.isTracking || scrollView.isDragging
                    ? .interacting
                    : scrollView.isDecelerating ? .decelerating
                    : animatingToLatest ? .animating : .idle
                if animatingToEvent {
                    newestScroll.targetEvent()
                } else {
                    newestScroll.observe(atBottom: value, phase: phase)
                }
                if parent.atBottom != value { parent.atBottom = value }
                let show = showsJumpToLatest(
                    contentHeight: scrollView.contentSize.height,
                    visibleBottom: scrollView.contentOffset.y + scrollView.bounds.height
                        - scrollView.adjustedContentInset.bottom,
                    viewportHeight: scrollView.bounds.height
                )
                if parent.showJumpToLatest != show { parent.showJumpToLatest = show }
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) { reportBottom(scrollView) }
            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
                animatingToLatest = false
                animatingToEvent = false
                newestScroll.observe(atBottom: isAtBottom(scrollView), phase: .tracking)
                reportBottom(scrollView)
            }
            func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
                reportBottom(scrollView)
                if !willDecelerate, let collectionView = scrollView as? UICollectionView {
                    pinLatestIfNeeded(collectionView)
                }
            }
            func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
                reportBottom(scrollView)
                if let collectionView = scrollView as? UICollectionView {
                    pinLatestIfNeeded(collectionView)
                }
            }
            func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
                animatingToLatest = false
                animatingToEvent = false
                reportBottom(scrollView)
                if let collectionView = scrollView as? UICollectionView {
                    pinLatestIfNeeded(collectionView)
                }
            }
        }
    }
#endif

/// A return shortcut is useful only when reaching the end would take more than one full swipe.
func showsJumpToLatest(contentHeight: CGFloat, visibleBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
    viewportHeight > 0 && contentHeight - visibleBottom > viewportHeight
}

/// First assistant message nobody had read when a notification was sent. Tool, progress and
/// approval rows are execution state, not the reply the notification announced.
func resumeRowId(
    rows: [ChatRow],
    lastReadAt: Double?,
    notificationClass: String? = nil,
    notificationEventRef: String? = nil
) -> String? {
    if let notificationEventRef {
        return rows.first(where: { YorozuCrypto.threadRef($0.id) == notificationEventRef })?.id
    }
    guard let lastReadAt else { return nil }
    return rows.first { row in
        switch notificationClass {
        case "approval":
            switch row {
            case .approval(let event), .question(let event):
                return Double(event.ts) > lastReadAt
            default:
                return false
            }
        default:
            guard case .message(let event) = row, Double(event.ts) > lastReadAt else { return false }
            if case .message(let message) = event.payload { return message.role == .agent }
            return false
        }
    }?.id
}

func notificationRefreshFinished(initialRevision: Int?, currentRevision: Int) -> Bool {
    guard let initialRevision else { return true }
    return currentRevision > initialRevision
}

/// Whether layout changes should keep the viewport on the newest content. `atBottom` is an
/// observation, not intent: replay or self-sizing can make it false without any reader input.
/// Only an actual interaction or an exact navigation target opts out; reaching/jumping to the
/// bottom opts back in.
struct NewestScrollIntent {
    private(set) var followsLatest = true

    mutating func observe(atBottom: Bool, phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting:
            followsLatest = false
        case .idle, .animating, .decelerating:
            if atBottom { followsLatest = true }
        }
    }

    mutating func followLatest() { followsLatest = true }

    mutating func targetEvent() { followsLatest = false }

    func shouldPinLatest(during phase: ScrollPhase) -> Bool {
        guard followsLatest else { return false }
        return switch phase {
        case .tracking, .interacting, .decelerating: false
        case .idle, .animating: true
        }
    }
}

/// The send and stop circle, inside the ``controlTarget``-tall row the composer's controls
/// share. Smaller than the row on both platforms, so the accent fill reads as a button rather
/// than as a block — and not derived from ``controlTarget``, because a glyph in a circle stops
/// being legible below about twenty points however small the row around it is.
#if os(macOS)
    private let sendCircle: CGFloat = 24
#else
    private let sendCircle: CGFloat = 32
#endif

extension View {
    /// Prose stops at a reading width and sits centred in whatever is left. On the Mac that is
    /// the whole transcript; on iOS it is each hosted row, because the timeline there is a
    /// collection view. A phone is never wider than the cap, so there it changes nothing — an
    /// iPad in landscape is, and a line of text running the full 1024 points was not readable.
    @ViewBuilder fileprivate func compactQuietTranscriptLayout() -> some View {
        #if os(macOS)
            frame(maxWidth: LayoutMetrics.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, LayoutMetrics.section)
                .padding(.vertical, LayoutMetrics.gutter)
        #else
            frame(maxWidth: LayoutMetrics.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        #endif
    }

    /// The composer keeps to the same column as the prose above it. Like the cap on the
    /// transcript, this is a no-op on a phone.
    @ViewBuilder fileprivate func compactQuietComposerLayout() -> some View {
        frame(maxWidth: LayoutMetrics.composerWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// A pointer hovering over a plain-styled button gets the system highlight on iPad, where
    /// a trackpad is common; the Mac's own controls already track the pointer.
    @ViewBuilder fileprivate func hoverHighlight() -> some View {
        #if os(iOS)
            hoverEffect(.highlight)
        #else
            self
        #endif
    }

    /// A key equivalent, on the Mac only.
    ///
    /// The composer's own `onKeyPress` never sees Return there: a `TextField` is an
    /// `NSTextField` underneath and handles its keys in AppKit, below the pipeline SwiftUI
    /// delivers key presses through. A key equivalent on the button is consulted first, by
    /// AppKit, so this is the one place the keystroke can be caught — and one with no
    /// modifiers leaves Shift-Return to the field, where it still inserts a newline.
    ///
    /// On iOS the composer's own text view catches Return and a key equivalent would double
    /// up, so there this does nothing.
    @ViewBuilder fileprivate func macKey(_ key: KeyEquivalent) -> some View {
        #if os(macOS)
            keyboardShortcut(key, modifiers: [])
        #else
            self
        #endif
    }
}

/// What "the thread changed" means for a view that has to notice a reply growing in place.
/// The count catches a new event and the last event's text catches a delta into the same one.
private struct ChangeStamp: Equatable {
    let count: Int
    let tail: String

    init(events: [YorozuEvent]) {
        count = events.count
        tail =
            switch events.last?.payload {
            case .message(let data): data.text
            default: events.last?.id ?? ""
            }
    }
}

/// Test-only, and empty unless the screenshot harness filled it in: the parts of a chat that
/// live in the view rather than in the model, and so cannot be seeded through ``ChatModel``.
@MainActor
public enum ChatShowcase {
    public static var imageViewer = false
    /// A term, which opens the search field over the transcript with it already typed.
    public static var search: String?
    /// Draws the "…" menu's Model choices as a popover over the toolbar. A screenshot needs
    /// them on screen and nothing on a simulator can open a real menu; the contents are the
    /// menu's own, not a copy of them.
    public static var modelMenu = false
    /// Puts the share extension's composer on screen. The app draws it only for a screenshot:
    /// nothing on a simulator can open a real share sheet on demand, and the composer is the
    /// part worth showing anyway.
    public static var share = false
    /// Draws long message and approval details already unfolded. Nothing on
    /// a simulator taps a button on demand, and the two states are the picture worth having.
    public static var expanded = false
    /// Opens the approval card's rule editor over the card. Same reason as ``modelMenu``:
    /// nothing on a simulator taps a button on demand, and the sheet is the part worth showing.
    public static var ruleEditor = false

    static func apply(search term: Binding<String>, searching: Binding<Bool>) {
        if let search {
            term.wrappedValue = search
            searching.wrappedValue = true
        }
    }
}

/// How many hits there are and which one you are on, over the transcript while searching.
private struct SearchHitBar: View {
    let index: Int
    let total: Int
    /// -1 for the hit above, +1 for the one below.
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(total == 0 ? "No matches" : "\(index + 1) of \(total)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            arrow("chevron.up", "Previous match", -1)
            arrow("chevron.down", "Next match", 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func arrow(_ symbol: String, _ label: String, _ direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .frame(width: controlTarget, height: controlTarget)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .disabled(total == 0)
        .accessibilityLabel(label)
    }
}

/// Names the next step truthfully: active work animates; a decision waiting on the reader does not.
private struct ChatActivityRow: View {
    let activity: ChatActivity
    let agent: ThreadAgent

    var body: some View {
        HStack(spacing: 8) {
            AgentMarkView(agent, size: 16)
            if let symbol = activity.symbol {
                Image(systemName: symbol).foregroundStyle(YorozuPalette.vermilion)
            } else {
                ProgressView().controlSize(.small).tint(YorozuPalette.vermilion)
            }
            Text(activity.label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Offered only when the reader has scrolled away from the end: a way back that does not move
/// the thread under them until they ask.
private struct ScrollToBottomPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Jump to latest", systemImage: "arrow.down")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .pillBackground()
        .hoverHighlight()
        .accessibilityLabel("Jump to latest message")
    }
}

/// A thread nobody has said anything in yet. Compact Quiet leaves it genuinely quiet: the
/// composer is already the action, so suggestion pills only repeat it and dominate the screen.
private struct EmptyThreadView: View {
    let presentation: ThreadPresentation

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutMetrics.stack) {
                AgentMarkView(presentation.agent, size: 42)
                Text(presentation.emptyTitle)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(YorozuPalette.ink)
                Text(presentation.emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(LayoutMetrics.section)
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }
}

/// A running turn lights the composer edge. Reduce Motion keeps the same state cue as a steady
/// bezel instead of pulsing it.
private struct WorkingBezel: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                YorozuPalette.vermilion.opacity(active ? (bright || reduceMotion ? 0.9 : 0.3) : 0),
                lineWidth: 2
            )
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: bright)
            .onChange(of: active, initial: true) { _, running in
                bright = running && !reduceMotion
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(YorozuPalette.stone.opacity(0.6))
    }
}

extension View {
    /// Search over the transcript, hidden until `presented` becomes true. iOS uses its navigation
    /// drawer; Mac uses the default toolbar placement.
    @ViewBuilder fileprivate func threadSearch(text: Binding<String>, presented: Binding<Bool>) -> some View {
        #if os(iOS)
            if presented.wrappedValue {
                searchable(
                    text: text,
                    isPresented: presented,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Find in thread"
                )
            } else {
                self
            }
        #else
            searchable(text: text, isPresented: presented, prompt: "Find in thread")
        #endif
    }

    /// Same idea for the jump-to-latest pill, which floats over the messages themselves and so
    /// needs to read as a control rather than as part of the thread.
    @ViewBuilder fileprivate func pillBackground() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}

/// The id of the message still arriving, or nil: the last message, only when it is an agent
/// reply not yet marked done. A user message sent after a finished reply is not a reply
/// streaming again.
func streamingMessageId(in events: [YorozuEvent]) -> String? {
    let last = events.last { if case .message = $0.payload { true } else { false } }
    guard let last, case .message(let data) = last.payload, data.role == .agent, data.done != true else { return nil }
    return last.id
}
