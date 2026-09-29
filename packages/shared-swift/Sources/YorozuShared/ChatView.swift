import SwiftUI

#if os(iOS)
    import UIKit
#endif

extension ModelOption {
    /// Preserves provider first appearance and each provider's model order.
    static func groupedByProvider(_ options: [ModelOption]) -> [(label: String, options: [ModelOption])] {
        var groups: [(label: String, options: [ModelOption])] = []
        for option in options {
            if let index = groups.firstIndex(where: { $0.label == option.providerLabel }) {
                groups[index].options.append(option)
            } else {
                groups.append((option.providerLabel, [option]))
            }
        }
        return groups
    }
}

/// One thread's messages, shared by both apps: the phone pushes it from ``ThreadListView``, the
/// Mac shows it as the detail half of its split view. Either way it has to sit inside a
/// navigation stack, which is what the trace drill-down pushes onto.
public struct ChatView: View {
    public let model: ChatModel
    public let thread: ThreadSummary
    private let hosts: MultiHostModel?
    private let hostID: HostID?
    private let onDraftMove: ((HostThreadID) -> Void)?
    private let onNewThread: (() -> Void)?
    private let onCreate: ((ThreadAgent, String?) -> String?)?
    private let resumeRequest: UUID?
    private let notificationClass: String?
    private let notificationEventRef: String?
    private let lastReadAt: Double?
    private let notificationSyncRevision: Int?
    private let showsUpdateStatus: Bool
    private let focusComposerOnAppear: Bool
    private let aggregateToast: ConnectionState?
    private let aggregateToastID: UUID?
    private let aggregateToastAnnouncementRevision: UInt64?
    private let aggregateToastLabel: String?
    /// Where a pairing code tapped in a message goes; the app sets it, and the default drops
    /// the link. See ``OpenURLAction/chatLinks(onPairingLink:)``.
    @Environment(\.onPairingLink) private var onPairingLink
    @Environment(\.threadSearchRequest) private var threadSearchRequest

    /// Whether geometry currently reaches the newest message. Reader intent is tracked
    /// separately because async row growth can make this false without any manual scroll.
    @State private var atBottom = true
    /// The shortcut stays out of the way while the reader is still at the newest edge.
    @State private var showJumpToLatest = false
    @State private var scrollPhase = ScrollPhase.idle
    #if os(macOS)
        @State private var macScrollPosition = ScrollPosition(idType: String.self)
    #endif
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
    @State private var dropTargeted = false
    @State private var searchRequestRevision = UUID()
    @State private var pendingExternalSearch = false
    @State private var externalSearchEventID: String?
    @State private var handledNotificationResume: UUID?
    #if os(macOS)
        @State private var handledMacNotificationScroll: UUID?
    #endif
    @State private var suppressedSearchRequest: UUID?
    @State private var supersededNotificationResume: UUID?
    @State private var highlightedNotificationRow: String?
    @State private var highlightRevision = UUID()
    #if os(macOS)
        @FocusState private var composerFocused: Bool
        @AppStorage(ChatView.sendWithCommandReturnKey) private var sendWithCommandReturn = false
    #endif
    @State private var channelModelPicker = false
    @State private var channelPickerWidth: CGFloat?
    @State private var searching = false
    @State private var choosingAgent = false
    @State private var recoveryMessage: MessageData?
    /// The draft the skill picker was closed over. An edit opens it again.
    @State private var dismissedSkillDraft: String?
    #if os(macOS)
        /// Which match the arrows are on. Reset whenever the draft changes.
        @State private var skillIndex = 0
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
        /// The model and effort card, open over the chat. Seeded open for the screenshot scene.
        @State private var runSettings = ChatShowcase.modelMenu
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var editingApprovalRule: ApprovalRule?
    @State private var editingApprovalId = ""
    /// Which hit the arrows are on. Reset whenever the term changes.
    @State private var hit = 0
    #if os(iOS)
        @State private var timelineRequest: TimelineRequest?
    #endif

    public init(
        model: ChatModel,
        thread: ThreadSummary,
        resumeRequest: UUID? = nil,
        notificationClass: String? = nil,
        notificationEventRef: String? = nil,
        lastReadAt: Double? = nil,
        notificationSyncRevision: Int? = nil,
        showsUpdateStatus: Bool = true,
        focusComposerOnAppear: Bool = false,
        aggregateToast: ConnectionState? = nil,
        aggregateToastID: UUID? = nil,
        aggregateToastAnnouncementRevision: UInt64? = nil,
        aggregateToastLabel: String? = nil,
        hosts: MultiHostModel? = nil,
        hostID: HostID? = nil,
        onDraftMove: ((HostThreadID) -> Void)? = nil,
        onNewThread: (() -> Void)? = nil,
        onCreate: ((ThreadAgent, String?) -> String?)? = nil
    ) {
        self.model = model
        self.thread = thread
        self.resumeRequest = resumeRequest
        self.notificationClass = notificationClass
        self.notificationEventRef = notificationEventRef
        self.lastReadAt = lastReadAt
        self.notificationSyncRevision = notificationSyncRevision
        self.showsUpdateStatus = showsUpdateStatus
        self.focusComposerOnAppear = focusComposerOnAppear
        self.aggregateToast = aggregateToast
        self.aggregateToastID = aggregateToastID
        self.aggregateToastAnnouncementRevision = aggregateToastAnnouncementRevision
        self.aggregateToastLabel = aggregateToastLabel
        self.hosts = hosts
        self.hostID = hostID
        self.onDraftMove = onDraftMove
        self.onNewThread = onNewThread
        self.onCreate = onCreate
    }

    private var presentation: ThreadPresentation {
        ThreadPresentation(thread: thread, descriptor: model.descriptor(for: thread.agent ?? .yorozu))
    }

    private var events: [YorozuEvent] { model.timeline(thread.id).events }

    private var rows: [ChatRow] { model.rows(in: thread.id) }

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
    /// A thread just started has nothing to read, so it opens ready to be typed into.
    private var startsFocused: Bool { model.startedThread == thread.id && events.isEmpty }
    private var shownToast: ConnectionState? { aggregateToast ?? model.connectionToast.visible }
    private var shownToastID: UUID? { aggregateToastID ?? model.connectionToast.notice?.id }
    private var toastAnnouncementKey: String? {
        guard let id = shownToastID, shownToast != nil,
              let revision = aggregateToastAnnouncementRevision ?? model.connectionToast.notice?.announcementRevision
        else { return nil }
        return "\(id.uuidString):\(revision)"
    }

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
        else { _ = onCreate?(.yorozu, nil) }
    }

    private var draftSelectors: some View {
        VStack {
            Button { choosingAgent = true } label: {
                Label("Agent: \(presentation.agentLabel)", systemImage: "chevron.up.chevron.down")
            }
            .accessibilityLabel("Choose agent")
            .accessibilityValue(presentation.agentLabel)
            .accessibilityHint("Coding agents require a project folder")
            if let hosts, let hostID, let host = hosts.session(for: hostID) {
                Button { choosingAgent = true } label: {
                    Label("Host: \(hosts.label(for: host))", systemImage: "desktopcomputer")
                }
                .accessibilityLabel("Choose host")
                .accessibilityValue(hosts.label(for: host))
                .disabled(!hosts.hasMultipleHosts)
                if !host.model.canDeliver {
                    Text("Mac offline — messages will queue")
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.bordered)
        .disabled(attachmentLoading)
    }

    public var body: some View {
        let queue = model.queuedMessages(in: thread.id)
        let queuedStatuses = model.queuedMessageStatuses(in: thread.id, queued: queue)
        let rows = model.rows(in: thread.id, queued: queue)
        VStack(spacing: 0) {
            if showsUpdateStatus {
                UpdateStatusView(status: model.updateStatus,
                    postpone: { model.updateControl(.postpone) },
                    installNow: model.supportsUpdateDrain ? { model.updateControl(.installNow) } : nil)
            }
            // A failure of this device's own, such as a draft that would not save. The link's
            // failures go in the connection toast below, after the grace, not in a banner.
            if let failure = model.failure, failure != model.linkFailure {
                Banner(text: failure, systemImage: "exclamationmark.triangle")
            }
            if model.hasUnconfirmedStop(in: thread.id) {
                Banner(text: "Could not confirm whether this task stopped. Check the host before retrying.",
                    systemImage: "exclamationmark.triangle")
            }
            if thread.interruptedTurnId != nil {
                VStack(alignment: .leading) {
                    Label("Couldn't resume automatically", systemImage: "pause.circle")
                    Text(thread.canResume == false ? "Original request is unavailable. Dismiss, then send it again." : "Three recovery attempts failed. Retry when ready.").font(.scaled(.callout))
                    HStack {
                        if thread.canResume != false {
                            Button("Retry") { model.recover(thread, action: .continue) }
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
                    EmptyThreadView(presentation: presentation) {
                        if model.isDraft(thread.id) { draftSelectors }
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Every link in a message is text the model wrote. Only the web and mail
                    // open from here; a pairing code is asked about first, the rest is dropped.
                    messages(rows: rows, queuedStatuses: queuedStatuses, firstQueuedId: queue.first?.id)
                        .environment(\.openURL, linkAction)
                }
            }
            // The Mac being away is a toast over the transcript, not a strip above it: the link
            // coming and going must not move the messages or the scroll anchor, and a blip
            // shorter than ``ConnectionPresentation/grace`` is never mentioned at all.
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if thread.recoveryState == "recovering" {
                        Label("Recovering…", systemImage: "arrow.clockwise")
                            .font(.scaled(.callout))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if let toast = shownToast {
                        ConnectionPill(state: toast, label: aggregateToastLabel)
                            .padding(.top, 8)
                            .padding(.horizontal)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                // Scoped here: an animation on the transcript would animate its scroll too.
                .allowsHitTesting(false)
                .animation(reduceMotion ? nil : .default, value: shownToastID)
            }
            // Over the transcript rather than above the composer: opening it must not move
            // the messages, and they stay readable around it.
            .overlay(alignment: .bottom) { skillPicker }
            composerCards
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Files and images dragged anywhere onto the conversation, from Finder, Files, Photos or
        // another app in Split View, go where the + menu and Paste put them.
        .dropDestination(for: DroppedFile.self) { files, _ in
            dropFiles(files)
        } isTargeted: { dropTargeted = $0 }
        .background(YorozuPalette.canvas.ignoresSafeArea())
        .yorozuTint()
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.connectionToast.dismiss() }
        }
        .onChange(of: toastAnnouncementKey) { _, key in
            if key != nil, let toast = shownToast {
                AccessibilityNotification.Announcement(aggregateToastLabel ?? toast.label).post()
            }
        }
        // A truncated tool result in this thread's trace asks the Mac for the rest through here.
        .environment(\.fetchToolResult) { model.requestToolResult($0, in: thread.id) }
        .sheet(isPresented: $choosingAgent) {
            if model.isDraft(thread.id), let hosts, let hostID {
                NewThreadPicker(session: hosts, draftID: HostThreadID(hostID: hostID, threadID: thread.id)) {
                    onDraftMove?($0)
                }
                .presentationDetents([.medium, .large])
            } else {
                NewThreadPicker(projects: model.projects, agents: model.availableAgents, status: model.projectListStatus,
                    onRefresh: { await model.refreshProjects() }, onStart: { agent, cwd in
                        if model.isDraft(thread.id) {
                            model.configureDraft(thread.id, agent: agent, cwd: cwd)
                        } else if let recoveryMessage, let id = onCreate?(agent, cwd) {
                            model.drafts[id] = recoveryMessage.text
                            model.attachments[id] = recoveryMessage.attachments
                        }
                        recoveryMessage = nil
                    })
                    .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: choosingAgent) { _, shown in
            if !shown { recoveryMessage = nil }
        }
        #if os(iOS)
            // In the view tree, not a sheet: a presented sheet resigns the composer, and the
            // keyboard and caret must survive choosing a model mid-sentence.
            .overlay(alignment: .bottom) {
                if runSettings && !model.models(for: thread).isEmpty {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                            .onTapGesture { setRunSettings(false) }
                            .accessibilityLabel("Close model and effort")
                            .accessibilityAddTraits(.isButton)
                        RunSettingsCard(
                            models: model.models(for: thread),
                            efforts: model.efforts(for: thread),
                            model: modelBinding,
                            effort: effortBinding
                        ) { setRunSettings(false) }
                            .padding(.horizontal, LayoutMetrics.stack)
                            .padding(.bottom, LayoutMetrics.inner)
                            .frame(maxWidth: LayoutMetrics.composerWidth)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
        #endif
        .onChange(of: draft.wrappedValue) { _, _ in
            dismissedSkillDraft = nil
            #if os(macOS)
                skillIndex = 0
            #endif
        }
        .onChange(of: model.state, initial: true) { _, state in
            if state == .paired { model.requestApprovalSettings() }
        }
        .navigationTitle(thread.displayTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(AgentSubtitle(text: presentation.agentLabel))
        #else
            // A thread on a model of its own says so beside its title. Only then — the default
            // is the case that needs no caption. The Mac has a title bar subtitle for exactly
            // this; the phone has one from iOS 26, and a compact identity in its `.principal`
            // item before that.
            .navigationSubtitle(macModelCaption)
            // The bar draws its own backdrop, always. Left to decide for itself it went clear
            // over a transcript that reached it and opaque over a project row that did not,
            // so the bar had an edge in one kind of thread and none in the other.
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #endif
        #if os(iOS)
        .toolbar {
                // From iOS 26 the bar lays a custom title view out at its ideal width and never
                // tells it how much room there is — on every iPhone, and worse on Duo's side
                // bar — so a long title ran under the buttons. The system title is the one
                // view the bar does truncate; only older bars, which clamp `titleView`, get this.
                if #unavailable(iOS 26) {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 7) {
                            AgentMarkView(presentation.agent, size: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(thread.displayTitle)
                                    .font(.scaled(.subheadline).weight(.semibold))
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(model.ownerOnline ? YorozuPalette.sage : Color.secondary)
                                        .frame(width: 5, height: 5)
                                        .accessibilityHidden(true)
                                    Text(presentation.agentLabel)
                                        .lineLimit(1)
                                }
                                .font(.scaled(.caption2))
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(model.ownerOnline ? String(localized: "Mac online") : String(localized: "Mac offline"))
                    }
                }
                if #available(iOS 27.1, *) {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Find in thread", systemImage: "magnifyingglass") { searching = true }
                            .keyboardShortcut("f")
                    }
                    if onNewThread != nil || onCreate != nil {
                        // Duo places bottom-bar actions at the lower end of its vertical bar.
                        ToolbarItem(placement: .bottomBar) {
                            Button("New session", systemImage: "square.and.pencil", action: newThread)
                                .keyboardShortcut("n")
                        }
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Find in thread", systemImage: "magnifyingglass") { searching = true }
                            .keyboardShortcut("f")
                        if onNewThread != nil || onCreate != nil {
                            Button("New session", systemImage: "square.and.pencil", action: newThread)
                                .keyboardShortcut("n")
                        }
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
            dismissedSkillDraft = nil
            #if os(macOS)
                skillIndex = 0
            #endif
            atBottom = true
            showJumpToLatest = false
            scrollPhase = .idle
            #if os(macOS)
                macScrollPosition = ScrollPosition(idType: String.self)
            #endif
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
            .onAppear { if focusComposerOnAppear || startsFocused { composerFocused = true } }
            .focusedSceneValue(
                \.chatCommands,
                ChatCommands(
                    find: { searching = true },
                    exportTitle: thread.displayTitle,
                    exportMarkdown: { threadMarkdown(thread: thread, events: events) },
                    stop: model.canStop(in: thread.id)
                        ? { model.interrupt(in: thread.id) } : nil,
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
        externalSearchEventID = nil
        #if os(iOS)
            timelineRequest = nil
        #endif
    }

    private func highlightNotificationRow(_ id: String) {
        let revision = UUID()
        highlightRevision = revision
        highlightedNotificationRow = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, highlightRevision == revision else { return }
            highlightedNotificationRow = nil
        }
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
        externalSearchEventID = request.eventId
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
        if presentation.needsFolder && thread.model == nil { return "Auto" }
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

    @ViewBuilder private func messages(rows: [ChatRow], queuedStatuses: [String: String],
                                       firstQueuedId: String?) -> some View {
        let activity = chatActivity(in: rows, generating: generating, streamingId: streamingId,
            answeredApprovals: model.answered, answeredQuestions: model.answeredQuestions)
        #if os(iOS)
            nativeMessages(rows: rows, activity: activity, queuedStatuses: queuedStatuses)
        #else
            // The split-view detail is reused across selections. Recreate the scroll container
            // so its default bottom anchor belongs to this thread, not the previous one.
            swiftUIMessages(rows: rows, activity: activity, queuedStatuses: queuedStatuses,
                firstQueuedId: firstQueuedId).id(thread.id)
        #endif
    }

    #if os(iOS)
        private func nativeMessages(rows: [ChatRow], activity: ChatActivity?,
                                    queuedStatuses: [String: String]) -> some View {
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
                highlightedRow: highlightedNotificationRow,
                presentation: TimelinePresentation(
                    search: search,
                    outbox: model.outbox,
                    queuedStatuses: queuedStatuses,
                    answered: model.answered,
                    approvalOutcomes: model.approvalOutcomes,
                    answeredQuestions: model.answeredQuestions,
                    questionChoices: model.questionChoices,
                    handledProposals: model.handledProposals,
                    choices: model.choices
                ),
                atBottom: $atBottom,
                showJumpToLatest: $showJumpToLatest,
                onNotificationTarget: { highlightNotificationRow($0) },
                content: { row in
                    AnyView(
                        rowView(row, queuedStatuses: queuedStatuses)
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
            if pendingExternalSearch, let externalSearchEventID {
                guard let index = hits.firstIndex(where: { $0.eventId == externalSearchEventID }) else { return }
                hit = index
            }
            guard hits.indices.contains(hit) else { return }
            pendingExternalSearch = false
            timelineRequest = TimelineRequest(target: .event(hits[hit].eventId))
        }
    #endif

    #if os(macOS)
    private func swiftUIMessages(rows: [ChatRow], activity: ChatActivity?,
                                 queuedStatuses: [String: String], firstQueuedId: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                // A delegation collapses to one card where it started and what the
                // specialist did is behind it; the main agent's own tool use is shown
                // here, grouped, where it happened.
                ForEach(rows) { row in
                    if row.id == firstQueuedId, let activity {
                        ChatActivityRow(activity: activity, agent: presentation.agent)
                    }
                    rowView(row, queuedStatuses: queuedStatuses)
                }
                if firstQueuedId == nil, let activity { ChatActivityRow(activity: activity, agent: presentation.agent) }
                Color.clear.frame(height: 1)
            }
            .scrollTargetLayout()
            .compactQuietTranscriptLayout()
            // Handed down rather than threaded through every bubble, block and table cell
            // between the field and the run of text a hit is inside.
            .environment(\.searchHighlight, search)
        }
        // A thread opens on its newest message, like every other chat: the anchor does it
        // during layout, so there is no jump from the top to watch on the way in.
        // A thread shorter than the window still starts under the title bar: aligned to
        // the bottom it sat below a content inset, and the bar drew its backdrop over all
        // of it. Each role is named so none depends on the order of the modifiers.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollPosition($macScrollPosition, anchor: .top)
        .onChange(of: rows.map(\.id), initial: true) { _, _ in
            scrollToMacNotification()
        }
        .onChange(of: resumeRequest, initial: true) { _, _ in
            scrollToMacNotification()
        }
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
        // The native edge stays current when a lazy bottom marker still has its old frame.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height
        } action: { oldHeight, newHeight in
            guard oldHeight != newHeight,
                  newestScroll.shouldPinLatest(during: scrollPhase)
            else { return }
            macScrollPosition.scrollTo(edge: .bottom)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.visibleRect.height > 0
                ? geometry.contentSize.height - geometry.visibleRect.maxY : 0
        } action: { _, distance in
            showJumpToLatest = distance > 40 && !newestScroll.followsLatest
        }
        // Every frame of a streaming reply lands here, not just every message: the text of
        // the last event grows in place, so its id alone would never change.
        .onChange(of: ChangeStamp(events: events)) { _, _ in
            noteReplyStart()
            guard newestScroll.shouldPinLatest(during: scrollPhase) else { return }
            // Streaming frames arrive faster than a scroll animation can finish. Starting
            // another animation for each one makes the viewport repeatedly retarget and
            // visibly hitch; following the growing edge needs no transition.
            macScrollPosition.scrollTo(edge: .bottom)
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
                    withAnimation(reduceMotion ? nil : .default) { macScrollPosition.scrollTo(edge: .bottom) }
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
            scrollToHit()
        }
        .onChange(of: hit) { _, _ in scrollToHit() }
        .onChange(of: searchRequestRevision) { _, _ in scrollToHit() }
        .onChange(of: hits, initial: true) { _, _ in
            if pendingExternalSearch { scrollToHit() }
        }
        .animation(reduceMotion ? nil : .snappy, value: search.isEmpty)
    }

    private func scrollToMacNotification() {
        guard let resumeRequest, resumeRequest != handledMacNotificationScroll else { return }
        let destination: String?
        if let notificationEventRef {
            guard let row = resumeRowId(rows: rows, lastReadAt: nil,
                notificationEventRef: notificationEventRef) else { return }
            destination = row
        } else {
            destination = nil
        }
        handledMacNotificationScroll = resumeRequest
        newestScroll.targetEvent()
        Task { @MainActor in
            await Task.yield()
            if let destination {
                macScrollPosition.scrollTo(id: destination, anchor: .center)
                highlightNotificationRow(destination)
            } else {
                macScrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    #endif

    @ViewBuilder private func rowView(_ row: ChatRow, queuedStatuses: [String: String]) -> some View {
        switch row {
        case .work(let work):
            WorkRowView(work: work).id(work.id)
        case .unreadable(let event):
            Label(String(localized: "Update Yorozu to see this event"), systemImage: "arrow.up.circle")
                .font(.scaled(.subheadline))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .id(event.id)
        case .message(let event):
            if case .message(let data) = event.payload {
                let outboxStatus = model.outboxStatus(of: event.id)
                let queuedStatus = queuedStatuses[event.id]
                let messageActions = model.messageActions(for: event)
                let rejectionReason = model.outboxRejectionReason(of: event.id)
                let needsNewChat = rejectionReason?.hasPrefix("thread-create-rejected:") == true ||
                    rejectionReason == "thread-not-created"
                MessageBubble(
                    id: event.id,
                    data: data,
                    streaming: event.id == streamingId,
                    copyAvailable: messageActions.copy,
                    timestamp: data.role == .agent && data.done == true ? event.ts : nil,
                    status: outboxStatus,
                    queuedStatus: queuedStatus,
                    rejectionReason: rejectionReason,
                    attachmentTransferLabels: model.attachmentTransferLabels(of: event.id),
                    onEditFromHere: data.role == .user && model.supportsRewind(in: thread.id)
                        ? { model.editFromHere(event) } : nil,
                    editFromHereEnabled: model.canEditFromHere(event),
                    onRetry: data.role == .user && (!needsNewChat || onCreate != nil) &&
                        (outboxStatus == nil || outboxStatus == .rejected || outboxStatus == .withdrawn)
                        ? { if needsNewChat {
                                recoveryMessage = data
                                choosingAgent = true
                            } else { retry(data) } } : messageActions.retry.map { prompt in
                                { retry(prompt) }
                            },
                    onSendNow: queuedStatus != nil && model.canSendNow(event)
                        ? { model.sendNow(event) } : nil,
                    onWithdraw: model.canWithdraw(event)
                        ? { model.withdraw(event.id) } : nil,
                    onDelete: { model.delete(event.id, in: thread.id) },
                    onResend: {
                        if model.outboxStatus(of: event.id) == .expired { model.stillSend(event.id) }
                        else { model.retry(event.id) }
                    },
                    agent: presentation.agent,
                    agentLabel: presentation.agentLabel
                )
                .id(event.id)
                .onAppear { model.requestAttachmentDownloads(event) }
                .onDisappear { model.stopAttachmentDownloads(event) }
                .notificationHighlight(highlightedNotificationRow == event.id)
            }
        case .changes(let event):
            if case .turnChanges(let data) = event.payload {
                VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                    Text("^[\(data.files.count) changed file](inflect: true)")
                        .font(.scaled(.subheadline).weight(.semibold))
                    ForEach(data.files, id: \.path) { file in
                        HStack {
                            Text(file.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: LayoutMetrics.inner)
                            Text("+\(file.added) −\(file.removed)")
                                .monospacedDigit()
                        }
                        .font(.scaled(.caption))
                    }
                }
                .yorozuPaperCard(padding: LayoutMetrics.inner)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .id(event.id)
            }
        case .approval(let event):
            if case .approvalCard(let card) = event.payload, !pendingComposerCards.contains(event) {
                ApprovalCardView(
                    card: card,
                    agentLabel: card.nativeAgent.map(model.agentLabel),
                    answered: model.answered.contains(card.actionId),
                    pending: model.approvalPending(card.actionId),
                    disposition: model.approvalOutcomes[card.actionId],
                    chosen: model.choices[card.actionId]
                ) { choice, rule in
                    model.answer(card.actionId, in: thread.id, choice, rule: rule)
                }
                .id(event.id)
                .notificationHighlight(highlightedNotificationRow == event.id)
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
            if case .questionCard(let card) = event.payload, !pendingComposerCards.contains(event) {
                QuestionCardView(
                    card: card,
                    agentLabel: card.nativeAgent.map(model.agentLabel),
                    answered: model.answeredQuestions.contains(card.questionId),
                    chosen: model.questionChoices[card.questionId]
                ) { model.answerQuestion(card.questionId, in: thread.id, $0) }
                .id(event.id)
                .notificationHighlight(highlightedNotificationRow == event.id)
            }
        }
    }

    /// Puts the current hit in the middle of the screen, where a hit being read wants to be.
    #if os(macOS)
    private func scrollToHit() {
        if pendingExternalSearch, let externalSearchEventID {
            guard let index = hits.firstIndex(where: { $0.eventId == externalSearchEventID }) else { return }
            hit = index
        }
        guard hits.indices.contains(hit) else { return }
        pendingExternalSearch = false
        newestScroll.targetEvent()
        withAnimation(reduceMotion ? nil : .default) { macScrollPosition.scrollTo(id: hits[hit].eventId, anchor: .center) }
    }

    #endif

    private func projectContext(_ path: String) -> some View {
        Label {
            Text(path)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "folder")
        }
        .font(.scaled(.caption))
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

    /// What the draft's slash is asking to choose from. Empty is no picker.
    private var skillChoices: [SkillOption] {
        let text = draft.wrappedValue
        guard text != dismissedSkillDraft else { return [] }
        return skillMatches(for: text, in: model.skills(for: thread))
    }

    #if os(macOS)
        private var highlightedSkillIndex: Int? {
            skillChoices.isEmpty ? nil : min(skillIndex, skillChoices.count - 1)
        }

        private func skillKey(_ key: SkillPickerKey) {
            let choices = skillChoices
            guard let index = highlightedSkillIndex else { return }
            switch key {
            case .down: skillIndex = (index + 1) % choices.count
            case .up: skillIndex = (index + choices.count - 1) % choices.count
            case .select: pick(choices[index])
            case .dismiss: dismissedSkillDraft = draft.wrappedValue
            }
        }
    #endif

    /// The trailing space ends the command's name, so the picker closes by the rule that
    /// opened it and the argument can be typed straight away.
    private func pick(_ skill: SkillOption) {
        draft.wrappedValue = "/\(skill.name) "
        #if os(macOS)
            composerFocused = true
        #endif
    }

    @ViewBuilder private var skillPicker: some View {
        let choices = skillChoices
        if !choices.isEmpty {
            // Measured, because the cap is a share of the transcript this floats over.
            GeometryReader { transcript in
                Group {
                    #if os(macOS)
                        SkillPicker(skills: choices, highlighted: highlightedSkillIndex,
                            onHover: { skillIndex = $0 },
                            onPick: pick, dismiss: { dismissedSkillDraft = draft.wrappedValue })
                    #else
                        SkillPicker(skills: choices, onPick: pick,
                            dismiss: { dismissedSkillDraft = draft.wrappedValue })
                    #endif
                }
                .frame(maxHeight: transcript.size.height * SkillPicker.transcriptShare(dynamicTypeSize))
                .compactQuietComposerLayout()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            channelPickerWidth = width
        }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .onChange(of: choices.count, initial: true) { _, count in
                AccessibilityNotification.Announcement(String(localized: "\(count) skills")).post()
            }
        }
    }

    private var pendingComposerCards: [YorozuEvent] { model.pendingComposerCards(in: thread.id) }
    private var hasPendingApproval: Bool {
        guard let event = pendingComposerCards.first else { return false }
        if case .approvalCard = event.payload { return true }
        return false
    }
    private var hasPendingQuestion: Bool {
        guard let event = pendingComposerCards.first else { return false }
        if case .questionCard = event.payload { return true }
        return false
    }
    private var composerPlaceholder: String {
        model.composerPlaceholder(in: thread.id, default: presentation.composerPlaceholder)
    }

    @ViewBuilder private var composerCards: some View {
        let cards = pendingComposerCards
        if let event = cards.first {
            VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                HStack {
                    if case .approvalCard = event.payload {
                        Label("Approval needed", systemImage: "hand.raised")
                    } else {
                        Label("Question", systemImage: "questionmark.bubble")
                    }
                    Spacer()
                    if cards.count > 1 { Text("1/\(cards.count)").foregroundStyle(.secondary) }
                }
                .font(.scaled(.subheadline).weight(.semibold))
                switch event.payload {
                case .approvalCard(let card):
                    Text(card.actionClass.replacingOccurrences(of: "-", with: " ").capitalized)
                        .font(.scaled(.headline))
                    if !card.target.isEmpty { Text(card.target).font(.scaled(.callout)).textSelection(.enabled) }
                    if let amount = card.amount {
                        Text(ApprovalAmountFormatter.string(amount: amount, currency: card.currency))
                            .font(.scaled(.headline).monospacedDigit())
                    }
                    ForEach(card.scope?.rows ?? [], id: \.label) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                    if let summary = card.scope?.contentSummary {
                        Text(summary).font(.scaled(.callout)).textSelection(.enabled)
                    }
                    if let items = card.items, !items.isEmpty {
                        Text(items.map(\.label).joined(separator: ", ")).font(.scaled(.callout))
                    }
                    if let consequence = card.scope?.consequence {
                        Text(consequence).font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                    if card.mustConfirm == true {
                        Text("Fresh approval required for this action")
                            .font(.scaled(.caption)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Approve") { model.answer(card.actionId, in: thread.id, .yes) }
                            .buttonStyle(.borderedProminent)
                        Button("Decline") { model.answer(card.actionId, in: thread.id, .no) }
                            .buttonStyle(.bordered)
                        if card.nativeAgent == nil {
                            Menu("More") {
                                Button("Allow for this task") { model.answer(card.actionId, in: thread.id, .task) }
                                Button("Discuss first") { model.answer(card.actionId, in: thread.id, .discuss) }
                                if card.mustConfirm != true, let rule = card.suggestedRule {
                                    Button("Always allow…") {
                                        editingApprovalId = card.actionId
                                        editingApprovalRule = rule
                                    }
                                }
                            }
                        }
                    }
                case .questionCard(let card):
                    Text(card.question).font(.scaled(.headline))
                    ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            model.answerQuestion(card.questionId, in: thread.id, option)
                        } label: {
                            Text(index < 9 ? "\(index + 1). \(option)" : option)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                default: EmptyView()
                }
            }
            .padding(LayoutMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YorozuPalette.paper, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius))
            .padding(.horizontal, 12)
            .sheet(item: $editingApprovalRule) { rule in
                RuleEditorView(rule: rule, title: "Always allow") { edited in
                    model.answer(editingApprovalId, in: thread.id, .always, rule: edited)
                    editingApprovalRule = nil
                } onCancel: {
                    editingApprovalRule = nil
                }
            }
        }
    }

    private func questionOption(_ number: Int) -> Bool {
        guard draft.wrappedValue.isEmpty,
              let event = pendingComposerCards.first,
              case .questionCard(let card) = event.payload,
              (1...9).contains(number), card.options.indices.contains(number - 1) else { return false }
        model.answerQuestionOption(number, in: thread.id)
        return true
    }

    private var composer: some View {
        // One surface, like Messages: the attach button, the field, the staged file and the
        // send control all live inside the same rounded container, so the eye reads one thing
        // to type into rather than three controls in a row.
        VStack(alignment: .leading, spacing: 0) {
            if let attachmentFailure {
                HStack(alignment: .top, spacing: 8) {
                    Label(attachmentFailure, systemImage: "exclamationmark.circle")
                        .font(.scaled(.caption))
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
                    .font(.scaled(.caption))
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
                    placeholder: composerPlaceholder,
                    onSubmit: { send(alternateDelivery: $0) },
                    onSendNextQueued: { model.sendNextQueued(in: thread.id) },
                    onQuestionOption: questionOption,
                    onPromptHistory: { model.recallPrompt(in: thread.id, older: $0) },
                    onPasteImage: { pasteImages() },
                    focusThread: startsFocused ? thread.id : nil
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)

                HStack(alignment: .center, spacing: 4) {
                    attachButton
                    stashMenu
                    if model.offersChannelModels(for: thread) { channelModelButton }
                    else if !model.models(for: thread).isEmpty { runSettingsButton }
                    Spacer(minLength: 4)
                    if model.stopPending(in: thread.id) {
                        stopPendingLabel
                    } else if model.canStop(in: thread.id) {
                        stopButton
                    }
                    sendButton
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            #else
                // Give writing its own row: model names and a running turn's Stop control
                // must never reduce the space available for the message itself.
                TextField(composerPlaceholder, text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.scaled(.body))
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit { draft.wrappedValue += "\n" }
                    .focused($composerFocused)
                    .background(composerKeyMonitor)
                    .accessibilityLabel(composerPlaceholder)

                HStack(alignment: .center, spacing: 4) {
                    attachButton
                    stashMenu
                    if model.offersChannelModels(for: thread) { channelModelButton }
                    else if !model.models(for: thread).isEmpty {
                        runSettingsButton.frame(maxWidth: 280, alignment: .leading)
                    }
                    Spacer(minLength: 4)
                    if model.stopPending(in: thread.id) {
                        stopPendingLabel
                    } else if model.canStop(in: thread.id) {
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
                    generating || dropTargeted ? YorozuPalette.vermilion.opacity(0.72) : YorozuPalette.rule.opacity(0.82),
                    lineWidth: generating || dropTargeted ? 1.5 : 0.8
                )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .compactQuietComposerLayout()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            channelPickerWidth = width
        }
    }

    private var channelModelButton: some View {
        Button {
            model.refreshChannelModels(in: thread)
            channelModelPicker = true
        } label: {
            HStack {
                Text(thread.model.flatMap { selected in
                    model.channelModels[thread.id]?.first(where: { $0.id == selected })?.label ?? selected
                } ?? String(localized: "Default"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
            }
            .font(.scaled(.subheadline))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("channelModelMenu")
        .accessibilityLabel("Model")
        .accessibilityValue(thread.model ?? String(localized: "Default"))
        .popover(isPresented: $channelModelPicker) {
            VStack(alignment: .leading) {
                HStack {
                    Text("Model").font(.scaled(.headline)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { channelModelPicker = false }
                }
                if let error = model.channelModelErrors[thread.id] {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { model.refreshChannelModels(in: thread) }
                }
                if model.channelModelsLoading.contains(thread.id) || model.channelModelPending.contains(thread.id) {
                    ProgressView("Updating models…")
                }
                ViewThatFits(in: .vertical) {
                    channelModelChoices
                    ScrollView { channelModelChoices }.scrollBounceBehavior(.basedOnSize)
                }
                .disabled(model.channelModelsLoading.contains(thread.id) || model.channelModelPending.contains(thread.id))
            }
            .padding()
            .frame(idealWidth: channelPickerWidth)
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.medium, .large])
        }
    }

    private var channelModelChoices: some View {
        YorozuChoiceCard([
            Choice(String(localized: "Default"), selected: thread.model == nil) { model.setModel(thread, nil) }
        ] + (model.channelModels[thread.id] ?? []).map { option in
            Choice(option.available ? option.label : "\(option.label) — \(option.unavailableReason ?? String(localized: "Unavailable"))",
                   selected: thread.model == option.id, enabled: option.available) {
                model.setModel(thread, option.id)
            }
        })
    }

    private var stashMenu: some View {
        Menu {
            Button("Stash draft", systemImage: "tray.and.arrow.down") {
                model.stashDraft(in: thread.id)
            }
            .disabled(draft.wrappedValue.isEmpty && attachments.wrappedValue.isEmpty || attachmentLoading)
            ForEach((model.stashes[thread.id] ?? []).reversed()) { stash in
                Button {
                    model.restoreStash(stash.id, in: thread.id)
                } label: {
                    Text(stash.text.isEmpty ? (stash.attachments.first?.name ?? "Draft") : stash.text)
                        .lineLimit(1)
                }
                .disabled(!draft.wrappedValue.isEmpty || !attachments.wrappedValue.isEmpty || attachmentLoading)
            }
        } label: {
            Image(systemName: "tray")
        }
        .accessibilityLabel("Draft stash")
        .help("Stash draft or restore a saved draft")
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

    private func dropFiles(_ files: [DroppedFile]) -> Bool {
        guard !attachmentLoading else { return false }
        attachmentFailure = nil
        stageAttachments(
            files.map(\.pick),
            remaining: MessageAttachment.maxCount - attachments.wrappedValue.count,
            onPick: addAttachments,
            onTooLarge: { attachmentTooLarge = true },
            onFailure: reportAttachmentFailure
        )
        return true
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

    #if os(iOS)
        private func setRunSettings(_ open: Bool) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { runSettings = open }
        }

        /// Opens the model and effort card. The Mac keeps its native menu below: an NSMenu is
        /// what a Mac control like this is expected to drop.
        private var runSettingsButton: some View {
            Button { setRunSettings(!runSettings) } label: { runSettingsChip }
                .buttonStyle(.plain)
                .accessibilityIdentifier("runSettingsMenu")
                .accessibilityLabel("Model and effort")
                .accessibilityValue("\(composerModelLabel), \(thread.effort?.label ?? "Default effort")")
        }
    #else
    private var runSettingsButton: some View {
        Menu {
            Text("Current model: \(composerModelLabel)")
            Text("Effort: \(thread.effort?.label ?? String(localized: "Default"))")
            Divider()

            Picker("Model", selection: modelBinding) {
                Text("Auto").tag(String?.none)
                // Grouped under the provider, but every row still names it: the OS owns the
                // menu's layout and is free to flatten the sections (iOS 27 does), and a row
                // that reads "claude-sonnet-5" alone would then have lost who runs it.
                ForEach(ModelOption.groupedByProvider(model.models(for: thread)), id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.options) { option in
                            Text(option.menuLabel).tag(Optional(option.id))
                        }
                    }
                }
            }
            Picker("Effort", selection: effortBinding) {
                Text("Default").tag(ReasoningEffort?.none)
                ForEach(model.efforts(for: thread)) { effort in
                    Text(effort.label).tag(Optional(effort))
                }
            }
        } label: {
            runSettingsChip
        }
        // A plain button, so the label above is what is drawn: the Mac's borderless menu
        // style drops the label's chevron, adds its own on the other side and tints the text.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("runSettingsMenu")
        .accessibilityLabel("Model and effort")
        .accessibilityValue("\(composerModelLabel), \(thread.effort?.label ?? "Default effort")")
    }
    #endif

    private var runSettingsChip: some View {
        HStack(spacing: 4) {
            Text(composerChipLabel).font(.scaled(.subheadline)).lineLimit(1)
            Image(systemName: "chevron.down").font(.scaled(.caption2))
        }
        // A caption, not an action: the send button is the one thing here in the tint.
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: controlTarget)
        .contentShape(Rectangle())
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

    /// Stop stays beside Send while the host is working.
    private var stopPendingLabel: some View {
        Text("Stopping…")
            .font(.scaled(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel("Stopping")
    }

    private var stopButton: some View {
        Button {
            model.interrupt(in: thread.id)
        } label: {
            Image(systemName: "stop.fill")
                .font(.scaled(.footnote).weight(.bold))
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
                .font(.scaled(.body).weight(.bold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .frame(width: sendCircle, height: sendCircle)
                .background(canSend ? YorozuPalette.vermilion : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: canSend ? 0 : 1.5))
        }
        .buttonStyle(.plain)
        .frame(width: controlTarget, height: controlTarget)
        .hoverHighlight()
        .disabled(!canSend)
        // Enter sends from the composer itself on both platforms: the phone's text view, and
        // the Mac's ``ComposerKeyMonitor``.
        .accessibilityLabel("Send")
    }

    private var canSend: Bool {
        !attachmentLoading && !hasPendingApproval && (
            !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (!hasPendingQuestion && !attachments.wrappedValue.isEmpty)
        )
    }

    #if os(macOS)
        /// The field handles Return, alternate delivery, and Send now before AppKit inserts a newline.
        private var composerKeyMonitor: some View {
            let onPaste: (() -> Void)? = { pasteImages() }
            let onPickerKey: ((SkillPickerKey) -> Void)? = skillChoices.isEmpty ? nil : { skillKey($0) }
            return ComposerKeyMonitor(
                isActive: composerFocused,
                sendModifiers: sendWithCommandReturn ? .command : [],
                onSend: sendFromKey,
                onSendNextQueued: { model.sendNextQueued(in: thread.id) },
                onPaste: onPaste,
                onPickerKey: onPickerKey,
                onQuestionOption: questionOption,
                onPromptHistory: { model.recallPrompt(in: thread.id, older: $0) }
            )
        }

        /// The send key's send: whether anything went, so an Enter with nothing to send is
        /// the field's to make a newline of.
        private func sendFromKey(_ alternateDelivery: Bool) -> Bool {
            guard canSend else { return false }
            send(alternateDelivery: alternateDelivery)
            return true
        }
    #endif

    private func send(alternateDelivery: Bool = false) {
        guard canSend else { return }
        model.send(in: thread, alternateDelivery: alternateDelivery)
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
        let queuedStatuses: [String: String]
        let answered: Set<String>
        let approvalOutcomes: [String: ApprovalStatusData.Status]
        let answeredQuestions: Set<String>
        let questionChoices: [String: String]
        let handledProposals: Set<String>
        let choices: [String: ApprovalAnswerData.Answer]
    }

    /// Reports every UIKit layout pass. A diffable snapshot can finish before hosted SwiftUI
    /// cells publish their final self-sized heights, so snapshot completion alone is not a safe
    /// "initial scroll finished" boundary.
    private final class TimelineCollectionView: UICollectionView {
        var willLayout: (() -> Void)?
        var didLayout: (() -> Void)?

        override func layoutSubviews() {
            willLayout?()
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
        let highlightedRow: String?
        let presentation: TimelinePresentation
        @Binding var atBottom: Bool
        @Binding var showJumpToLatest: Bool
        let onNotificationTarget: (String) -> Void
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
            private struct VisibleAnchor {
                let entry: Entry
                let distanceFromTop: CGFloat
            }

            var parent: IOSChatTimeline
            private var dataSource: UICollectionViewDiffableDataSource<Int, Entry>?
            private var rowsById: [String: ChatRow] = [:]
            private var previousRows: [String: ChatRow] = [:]
            private var previousPresentation: TimelinePresentation?
            private var previousHighlightedRow: String?
            private var lastRequest: UUID?
            private var lastNotificationRequest: TimelineRequest?
            private var newestScroll = NewestScrollIntent()
            private var animatingToLatest = false
            private var animatingToEvent = false
            private var snapshotAnchor: VisibleAnchor?
            private var layoutAnchor: VisibleAnchor?

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
                    timeline.willLayout = { [weak self, weak timeline] in
                        guard let self, let timeline, self.snapshotAnchor == nil,
                              !self.newestScroll.followsLatest, !self.animatingToEvent else { return }
                        self.layoutAnchor = self.visibleAnchor(in: timeline)
                    }
                    timeline.didLayout = { [weak self, weak timeline] in
                        guard let self, let timeline else { return }
                        if let anchor = self.snapshotAnchor ?? self.layoutAnchor {
                            self.restore(anchor, in: timeline)
                        }
                        self.layoutAnchor = nil
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
                if let activity = parent.activity {
                    let next = parent.rows.firstIndex { parent.presentation.queuedStatuses[$0.id] != nil } ?? entries.endIndex
                    entries.insert(.activity(activity), at: next)
                }

                var changed = parent.rows.compactMap { previousRows[$0.id] == $0 ? nil : Entry.row($0.id) }
                if previousPresentation != parent.presentation { changed = entries }
                if previousHighlightedRow != parent.highlightedRow {
                    for id in [previousHighlightedRow, parent.highlightedRow].compactMap({ $0 }) {
                        changed.append(.row(id))
                    }
                }
                previousRows = rowsById
                previousPresentation = parent.presentation
                previousHighlightedRow = parent.highlightedRow

                let previousEntries = dataSource?.snapshot().itemIdentifiers ?? []
                guard !changed.isEmpty || entries != previousEntries else {
                    applyRequest(collectionView)
                    return
                }
                if snapshotAnchor == nil && !newestScroll.followsLatest && !animatingToEvent {
                    snapshotAnchor = visibleAnchor(in: collectionView)
                }
                var snapshot = NSDiffableDataSourceSnapshot<Int, Entry>()
                snapshot.appendSections([0])
                snapshot.appendItems(entries)
                let existing = Set(previousEntries)
                let current = Set(entries)
                snapshot.reconfigureItems(Array(Set(changed.filter { existing.contains($0) && current.contains($0) })))
                dataSource?.apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    collectionView.layoutIfNeeded()
                    if let anchor = self.snapshotAnchor { self.restore(anchor, in: collectionView) }
                    self.snapshotAnchor = nil
                    self.pinLatestIfNeeded(collectionView)
                    self.applyRequest(collectionView)
                    self.reportBottom(collectionView)
                }
            }

            private func visibleAnchor(in collectionView: UICollectionView) -> VisibleAnchor? {
                let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
                return collectionView.indexPathsForVisibleItems.compactMap { path -> (Entry, CGFloat)? in
                    guard let entry = dataSource?.itemIdentifier(for: path),
                          let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return nil }
                    return (entry, frame.minY)
                }
                .min(by: { $0.1 < $1.1 })
                .map { VisibleAnchor(entry: $0.0, distanceFromTop: $0.1 - top) }
            }

            private func restore(_ anchor: VisibleAnchor, in collectionView: UICollectionView) {
                guard let path = dataSource?.indexPath(for: anchor.entry),
                      let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return }
                let inset = collectionView.adjustedContentInset
                let minimum = -inset.top
                let maximum = max(minimum, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
                let desired = min(maximum, max(minimum, frame.minY - anchor.distanceFromTop - inset.top))
                if abs(collectionView.contentOffset.y - desired) > 0.5 {
                    collectionView.contentOffset.y = desired
                }
            }

            private func applyRequest(_ collectionView: UICollectionView) {
                let request: TimelineRequest
                if let notification = parent.notificationRequest,
                   notification != lastNotificationRequest {
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
                snapshotAnchor = nil
                layoutAnchor = nil
                switch request.target {
                case .latest:
                    if request.id == parent.notificationRequest?.id { lastNotificationRequest = request }
                    newestScroll.followLatest()
                    animatingToEvent = false
                    scrollToLatest(collectionView, animated: !UIAccessibility.isReduceMotionEnabled)
                case .event(let id):
                    guard let index = dataSource?.snapshot().indexOfItem(.row(id)) else { return }
                    if request.id == parent.notificationRequest?.id { lastNotificationRequest = request }
                    let animated = !UIAccessibility.isReduceMotionEnabled
                    newestScroll.targetEvent()
                    animatingToLatest = false
                    animatingToEvent = animated
                    collectionView.scrollToItem(
                        at: IndexPath(item: index, section: 0),
                        at: .centeredVertically,
                        animated: animated
                    )
                    if request.id == parent.notificationRequest?.id {
                        Task { @MainActor [parent] in parent.onNotificationTarget(id) }
                    }
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
                !showsJumpToLatest(
                    contentHeight: scrollView.contentSize.height,
                    visibleBottom: scrollView.contentOffset.y + scrollView.bounds.height
                        - scrollView.adjustedContentInset.bottom,
                    viewportHeight: scrollView.bounds.height
                )
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
                let show = !newestScroll.followsLatest && showsJumpToLatest(
                    contentHeight: scrollView.contentSize.height,
                    visibleBottom: scrollView.contentOffset.y + scrollView.bounds.height
                        - scrollView.adjustedContentInset.bottom,
                    viewportHeight: scrollView.bounds.height
                )
                if parent.showJumpToLatest != show { parent.showJumpToLatest = show }
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                reportBottom(scrollView)
            }
            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
                snapshotAnchor = nil
                layoutAnchor = nil
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

/// The same slack as bottom detection keeps the shortcut hidden until content is truly below.
func showsJumpToLatest(contentHeight: CGFloat, visibleBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
    viewportHeight > 0 && contentHeight - visibleBottom > 40
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
}

extension ChatView {
    /// `UserDefaults` key for the Mac's choice of send key: true for ⌘Enter, false for Enter.
    public static let sendWithCommandReturnKey = "sendWithCommandReturn"
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
    /// Opens the composer's model and effort card on the phone. A screenshot needs it on
    /// screen and nothing on a simulator taps a button on demand; the card is the real one.
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
                .font(.scaled(.footnote).monospacedDigit())
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
                .font(.scaled(.footnote).weight(.semibold))
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
            Text(activity.label).font(.scaled(.caption)).foregroundStyle(.secondary)
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
            Label("Scroll to bottom", systemImage: "arrow.down")
                .font(.scaled(.footnote).weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .pillBackground()
        .hoverHighlight()
        .accessibilityLabel("Scroll to bottom")
    }
}

/// A thread nobody has said anything in yet. Compact Quiet leaves it genuinely quiet: the
/// composer is already the action, so suggestion pills only repeat it and dominate the screen.
private struct EmptyThreadView<Controls: View>: View {
    let presentation: ThreadPresentation
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutMetrics.stack) {
                AgentMarkView(presentation.agent, size: 42)
                Text(presentation.emptyTitle)
                    .font(.scaled(.title3).weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(YorozuPalette.ink)
                controls()
                Text(presentation.emptyMessage)
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(LayoutMetrics.section)
            .accessibilityElement(children: .contain)
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
            .font(.scaled(.footnote))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(YorozuPalette.stone.opacity(0.6))
    }
}

extension View {
    fileprivate func notificationHighlight(_ active: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color.accentColor, lineWidth: 2)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(false))
    }

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

#if os(iOS)
    /// The agent's name under the title, where the `.principal` item used to carry it.
    private struct AgentSubtitle: ViewModifier {
        let text: String

        func body(content: Content) -> some View {
            if #available(iOS 26, *) {
                content.navigationSubtitle(text)
            } else {
                content
            }
        }
    }
#endif
