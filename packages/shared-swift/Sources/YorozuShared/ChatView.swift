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
    private let onCreate: (() -> Void)?
    private let resumeRequest: UUID?
    private let notificationClass: String?
    private let notificationEventRef: String?
    private let lastReadAt: Double?
    private let notificationSyncRevision: Int?
    /// Shown while the runtime is unreachable. The two apps lose it differently: the phone
    /// queues what is typed and sends it when the Mac is back, the Mac's sidecar is simply not
    /// running yet.
    public let offlineNotice: String

    /// Whether the reader is already at the newest message. Only then does a new one scroll the
    /// thread — pulling someone away from what they were reading is the thing to avoid.
    @State private var atBottom = true
    /// The shortcut stays out of the way until the reader is over one viewport from the end.
    @State private var showJumpToLatest = false
    @State private var scrollPhase = ScrollPhase.idle
    /// Bumped on every send, so the haptic fires per send rather than per keystroke.
    @State private var sends = 0
    /// Id of the reply whose first token just landed, which is the moment worth a tap.
    @State private var replyStarted: String?
    @State private var attachmentTooLarge = false
    /// The message being replied to, quoted above the field until it is sent or dismissed.
    @State private var replyQuote: String?
    @State private var searching = false
    /// Screenshot only: draws the model menu's own contents as a popover, because nothing on a
    /// simulator can open a real menu. See ``ChatShowcase``.
    @State private var modelShowcase = ChatShowcase.modelMenu
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
        onCreate: (() -> Void)? = nil,
        offlineNotice: String = "Mac offline — what you send waits on this phone until it's back."
    ) {
        self.model = model
        self.thread = thread
        self.resumeRequest = resumeRequest
        self.notificationClass = notificationClass
        self.notificationEventRef = notificationEventRef
        self.lastReadAt = lastReadAt
        self.notificationSyncRevision = notificationSyncRevision
        self.onCreate = onCreate
        self.offlineNotice = offlineNotice
    }

    private var events: [YorozuEvent] { model.events[thread.id] ?? [] }

    private var rows: [ChatRow] { chatRows(from: events) }

    private var generating: Bool { model.generating.contains(thread.id) }

    /// Every occurrence of the search term in this thread, in reading order.
    private var hits: [SearchHit] { searchHits(in: events, term: search) }

    private var draft: Binding<String> {
        Binding(get: { model.drafts[thread.id] ?? "" }, set: { model.drafts[thread.id] = $0 })
    }

    private var attachments: Binding<[MessageAttachment]> {
        Binding(get: { model.attachments[thread.id] ?? [] }, set: { model.attachments[thread.id] = $0 })
    }

    /// The last agent message, which is the only one that can still be streaming.
    private var streamingId: String? {
        guard generating else { return nil }
        return events.last { event in
            if case .message(let data) = event.payload, data.role == .agent { return true }
            return false
        }?.id
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.ownerOnline {
                Banner(text: offlineNotice, systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            }
            if let failure = model.failure {
                Banner(text: failure, systemImage: "exclamationmark.triangle")
            }
            if rows.isEmpty {
                EmptyThreadView { prompt in
                    draft.wrappedValue = prompt
                    send()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messages
            }
            composer
        }
        // `ignoresSafeArea` carries the running cue through the navigation header instead of
        // framing only the message viewport. It remains an overlay, so title/menu taps still land.
        .overlay { WorkingBezel(active: generating).ignoresSafeArea() }
        .navigationTitle(thread.displayTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #else
            // A thread on a model of its own says so beside its title. Only then — the default
            // is the case that needs no caption. The Mac has a title bar subtitle for exactly
            // this; the phone's stacked `.principal` item is squeezed between the title it
            // repeats and the buttons next to it when a window toolbar draws it.
            .navigationSubtitle(modelCaption ?? "")
        #endif
        .toolbar {
            #if os(iOS)
                // A thread on a model of its own says so under its title, since a phone's
                // navigation bar has nowhere else to put a caption.
                if let caption = modelCaption {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(thread.displayTitle)
                                .font(.headline)
                                .lineLimit(1)
                            Text(caption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    #if os(iOS)
                        Button("Find in thread", systemImage: "magnifyingglass") { searching = true }
                        modelPicker
                        effortPicker
                        Divider()
                    #endif
                    ExportThreadButton(title: thread.displayTitle) {
                        threadMarkdown(thread: thread, events: events)
                    }
                }
            }
            #if os(iOS)
                if let onCreate {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New session", systemImage: "square.and.pencil", action: onCreate)
                    }
                }
            #endif
        }
        // Screenshot only: the menu's own choices, raised far enough down the screen that the
        // caption they set is in the same picture. Nothing on a simulator can open a real menu.
        .sheet(isPresented: $modelShowcase) {
            List { modelPicker }.presentationDetents([.fraction(0.45)])
        }
        // Opened from the magnifier rather than always on show: a thread is for reading, and
        // a permanent search field would be one more thing to read past — and on iOS 26 it
        // would be one more bar under the composer, which already owns the bottom of a chat.
        .threadSearch(text: $search, presented: $searching)
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
            ChatShowcase.apply(search: $search, searching: $searching, quote: $replyQuote)
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
                    models: model.models,
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

    /// The thread's model as the menu offers it: Default, then every spec the Mac published,
    /// with a tick against the one in force. Inline, so it draws as a list of choices rather
    /// than as a submenu of a submenu.
    @ViewBuilder private var modelPicker: some View {
        Picker("Model", selection: modelBinding) {
            Text("Default").tag(String?.none)
            ForEach(model.models) { option in
                Text(option.menuLabel).tag(String?.some(option.id))
            }
        }
        .pickerStyle(.inline)
    }

    private var modelBinding: Binding<String?> {
        Binding(get: { thread.model }, set: { model.setModel(thread, $0) })
    }

    @ViewBuilder private var effortPicker: some View {
        Picker("Effort", selection: effortBinding) {
            Text("Default").tag(ReasoningEffort?.none)
            ForEach(ReasoningEffort.allCases) { effort in
                Text(effort.label).tag(ReasoningEffort?.some(effort))
            }
        }
        .pickerStyle(.inline)
    }

    private var effortBinding: Binding<ReasoningEffort?> {
        Binding(get: { thread.effort }, set: { model.setEffort(thread, $0) })
    }

    /// What the caption under the title says, or nil for a thread on the default chain. A spec
    /// the Mac no longer offers still gets a caption: the thread really is set to it, and
    /// saying so is how the user finds out it wants changing.
    private var modelCaption: String? {
        guard let spec = thread.model else { return nil }
        return model.models.first { $0.id == spec }?.menuLabel ?? spec
    }

    @ViewBuilder private var messages: some View {
        #if os(iOS)
            nativeMessages
        #else
            swiftUIMessages
        #endif
    }

    #if os(iOS)
        private var nativeMessages: some View {
            let notificationRequest = resumeRequest.flatMap { id -> TimelineRequest? in
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
                generating: generating,
                streamingId: streamingId,
                request: timelineRequest,
                notificationRequest: notificationRequest,
                presentation: TimelinePresentation(
                    search: search,
                    outbox: model.outbox,
                    answered: model.answered,
                    answeredQuestions: model.answeredQuestions,
                    handledProposals: model.handledProposals,
                    choices: model.choices,
                    reactions: Dictionary(uniqueKeysWithValues: rows.map {
                        ($0.id, model.reactions(to: $0.id, in: thread.id))
                    })
                ),
                atBottom: $atBottom,
                showJumpToLatest: $showJumpToLatest,
                content: { row in AnyView(rowView(row).environment(\.searchHighlight, search)) }
            )
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
            .animation(.snappy, value: showJumpToLatest)
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
            .animation(.snappy, value: search.isEmpty)
        }

        private func requestCurrentHit() {
            guard hits.indices.contains(hit) else { return }
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
                    // Waiting with nothing drawn yet: the turn has started but the first token
                    // has not landed, so there is no bubble to put a caret on.
                    if generating, streamingId == nil {
                        ThinkingRow()
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding()
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
                guard followsNewest(atBottom: atBottom, phase: scrollPhase) else { return }
                // Streaming frames arrive faster than a scroll animation can finish. Starting
                // another animation for each one makes the viewport repeatedly retarget and
                // visibly hitch; following the growing edge needs no transition.
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onScrollPhaseChange { _, phase in scrollPhase = phase }
            .overlay(alignment: .bottom) {
                // Not while searching: the arrows are already moving the thread about, and a
                // pill offering to jump somewhere else would be arguing with them.
                if showJumpToLatest, search.isEmpty {
                    ScrollToBottomPill {
                        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: showJumpToLatest)
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
            .animation(.snappy, value: search.isEmpty)
        }
    }

    @ViewBuilder private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .message(let event):
            if case .message(let data) = event.payload {
                MessageBubble(
                    id: event.id,
                    data: data,
                    streaming: event.id == streamingId,
                    status: model.outboxStatus(of: event.id),
                    onRetry: data.role == .user ? { retry(data) } : nil,
                    onDelete: { model.delete(event.id, in: thread.id) },
                    onReply: { replyQuote = $0 },
                    onResend: { model.retry(event.id) },
                    reactions: model.reactions(to: event.id, in: thread.id),
                    onReact: { model.react(to: event.id, with: $0, in: thread.id) }
                )
                .id(event.id)
            }
        case .tools(let activities):
            ToolGroupView(activities: activities)
        case .delegation(let card):
            DelegationCardView(card: card).id(card.id)
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
                    answered: model.answeredQuestions.contains(card.questionId)
                ) { model.answerQuestion(card.questionId, in: thread.id, $0) }
                .id(event.id)
            }
        case .progress(let event):
            if case .progressCard(let card) = event.payload {
                ProgressCardView(card: card).id(event.id)
            }
        }
    }

    /// Puts the current hit in the middle of the screen, where a hit being read wants to be.
    private func scrollToHit(_ proxy: ScrollViewProxy) {
        guard hits.indices.contains(hit) else { return }
        withAnimation { proxy.scrollTo(hits[hit].eventId, anchor: .center) }
    }

    private var composer: some View {
        // One surface, like Messages: the attach button, the field, the staged file and the
        // send control all live inside the same rounded container, so the eye reads one thing
        // to type into rather than three controls in a row.
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.wrappedValue.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachments.wrappedValue.enumerated()), id: \.offset) { index, staged in
                            StagedAttachment(attachment: staged) {
                                attachments.wrappedValue.remove(at: index)
                            }
                            .frame(width: 240)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let quote = replyQuote {
                ReplyChip(text: quote) { replyQuote = nil }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 4) {
                AttachButton(
                    onPick: { picked in
                        let combined = attachments.wrappedValue + picked
                        guard combined.count <= MessageAttachment.maxCount,
                            combined.compactMap(\.bytes).reduce(0, { $0 + $1.count })
                                <= MessageAttachment.maxTotalBytes
                        else { return attachmentTooLarge = true }
                        attachments.wrappedValue = combined
                    },
                    onTooLarge: { attachmentTooLarge = true }
                )
                .disabled(generating)
                TextField("Message Yorozu", text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .padding(.vertical, composerPadding)
                    .frame(minHeight: controlTarget)
                    // Hardware keyboards only, which is the whole point: on a paired iPad,
                    // Return sends and Shift-Return keeps typing. The on-screen keyboard never
                    // gets here, so its Return still inserts a newline. The Mac takes the same
                    // pair as key equivalents on the send and stop buttons instead — see
                    // ``View/macKey(_:)``, which explains why this modifier is not enough there.
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        send()
                        return .handled
                    }
                    .accessibilityLabel("Message")
                    // Shift-Return, on the Mac. AppKit's field editor ends editing on Return
                    // whatever else is held down, and it is Shift-Return that gets there: plain
                    // Return is taken first by the send button's key equivalent, which is why
                    // `onSubmit` here means "Shift-Return" and not "Return". Ending editing also
                    // selects the whole field, so without this the next keystroke would replace
                    // the message rather than continue it.
                    #if os(macOS)
                        .onSubmit { draft.wrappedValue += "\n" }
                    #endif
                if generating {
                    stopButton
                }
                sendButton
                    .padding(.trailing, 6)
            }
            #if os(macOS)
                HStack(spacing: 12) {
                    Menu {
                        modelPicker
                    } label: {
                        Label(modelCaption ?? String(localized: "Model"), systemImage: "cpu")
                            .lineLimit(1)
                    }
                    .disabled(model.models.isEmpty)
                    Menu {
                        effortPicker
                    } label: {
                        Label(thread.effort?.label ?? String(localized: "Effort"), systemImage: "gauge.with.dots.needle.33percent")
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            #endif
        }
        .background(fieldBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.separator.opacity(0.6))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .animation(.easeOut(duration: 0.18), value: attachments.wrappedValue.count)
        .animation(.easeOut(duration: 0.18), value: generating)
        .animation(.easeOut(duration: 0.18), value: replyQuote != nil)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var fieldBackground: Color {
        #if os(iOS)
            Color(.secondarySystemGroupedBackground)
        #else
            Color(nsColor: .textBackgroundColor)
        #endif
    }

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
        .macKey(.escape)
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
                .background(canSend ? Color.accentColor : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: canSend ? 0 : 1.5))
        }
        .buttonStyle(.plain)
        .frame(width: controlTarget, height: controlTarget)
        .disabled(!canSend)
        .macKey(.return)
        .accessibilityLabel("Send")
        .animation(.easeOut(duration: 0.15), value: canSend)
    }

    private var canSend: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.wrappedValue.isEmpty
    }

    private func send() {
        guard canSend else { return }
        // The quote goes into the message itself, as a blockquote, so a reply is one ordinary
        // message and no client, cache or runtime has to learn a new field for it.
        if let quote = replyQuote {
            draft.wrappedValue = quotedMessage(quoting: quote, body: draft.wrappedValue)
            replyQuote = nil
        }
        model.send(in: thread)
        sends += 1
        // Sending is always a jump to the end: it is your own message, and you meant it.
        atBottom = true
    }

    /// Sends the same thing again, as a new message. The original stays where it is — a
    /// transcript that quietly rewrote itself would not be one.
    private func retry(_ data: MessageData) {
        model.send(data.text, in: thread.id, attachments: data.attachments)
        sends += 1
        atBottom = true
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
        let handledProposals: Set<String>
        let choices: [String: ApprovalAnswerData.Answer]
        let reactions: [String: [MessageReaction]]
    }

    /// Signal-style native timeline for iOS. Diffable updates touch only changed visible rows;
    /// UIKit owns gesture arbitration and scroll continuity instead of rebuilding one SwiftUI
    /// scroll tree as a reply grows.
    private struct IOSChatTimeline: UIViewRepresentable {
        let rows: [ChatRow]
        let generating: Bool
        let streamingId: String?
        let request: TimelineRequest?
        let notificationRequest: TimelineRequest?
        let presentation: TimelinePresentation
        @Binding var atBottom: Bool
        @Binding var showJumpToLatest: Bool
        let content: (ChatRow) -> AnyView

        private enum Entry: Hashable {
            case row(String)
            case thinking
        }

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UICollectionView {
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            let collectionView = UICollectionView(
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
            private var didInitialScroll = false

            init(_ parent: IOSChatTimeline) { self.parent = parent }

            func install(on collectionView: UICollectionView) {
                let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Entry> {
                    [weak self] cell, _, entry in
                    guard let self else { return }
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    cell.contentConfiguration = UIHostingConfiguration {
                        switch entry {
                        case .row(let id):
                            if let row = self.rowsById[id] { self.parent.content(row) }
                        case .thinking:
                            ThinkingRow()
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
            }

            func update(_ collectionView: UICollectionView) {
                rowsById = Dictionary(parent.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                var entries = parent.rows.map { Entry.row($0.id) }
                if parent.generating, parent.streamingId == nil { entries.append(.thinking) }

                let shouldFollow = isAtBottom(collectionView) && !collectionView.isTracking
                    && !collectionView.isDragging && !collectionView.isDecelerating
                var changed = parent.rows.compactMap { previousRows[$0.id] == $0 ? nil : Entry.row($0.id) }
                if previousPresentation != parent.presentation { changed = entries }
                previousRows = rowsById
                previousPresentation = parent.presentation

                var snapshot = NSDiffableDataSourceSnapshot<Int, Entry>()
                snapshot.appendSections([0])
                snapshot.appendItems(entries)
                let existing = Set(dataSource?.snapshot().itemIdentifiers ?? [])
                snapshot.reconfigureItems(changed.filter { existing.contains($0) && entries.contains($0) })
                dataSource?.apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    collectionView.layoutIfNeeded()
                    if !self.didInitialScroll || shouldFollow {
                        self.scrollToLatest(collectionView, animated: false)
                        self.didInitialScroll = true
                    }
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
                    scrollToLatest(collectionView, animated: true)
                case .event(let id):
                    guard let index = dataSource?.snapshot().indexOfItem(.row(id)) else { return }
                    collectionView.scrollToItem(
                        at: IndexPath(item: index, section: 0),
                        at: .centeredVertically,
                        animated: true
                    )
                }
            }

            private func scrollToLatest(_ collectionView: UICollectionView, animated: Bool) {
                let count = collectionView.numberOfItems(inSection: 0)
                guard count > 0 else { return }
                collectionView.scrollToItem(
                    at: IndexPath(item: count - 1, section: 0),
                    at: .bottom,
                    animated: animated
                )
            }

            private func isAtBottom(_ scrollView: UIScrollView) -> Bool {
                scrollView.contentOffset.y + scrollView.adjustedContentInset.top
                    + scrollView.bounds.height >= scrollView.contentSize.height - 40
            }

            private func reportBottom(_ scrollView: UIScrollView) {
                let value = isAtBottom(scrollView)
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
            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { reportBottom(scrollView) }
            func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
                reportBottom(scrollView)
            }
            func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportBottom(scrollView) }
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

func followsNewest(atBottom: Bool, phase: ScrollPhase) -> Bool {
    guard atBottom else { return false }
    return switch phase {
    case .tracking, .interacting, .decelerating: false
    case .idle, .animating: true
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
    /// A key equivalent, on the Mac only.
    ///
    /// The composer's own `onKeyPress` never sees Return there: a `TextField` is an
    /// `NSTextField` underneath and handles its keys in AppKit, below the pipeline SwiftUI
    /// delivers key presses through. A key equivalent on the button is consulted first, by
    /// AppKit, so this is the one place the keystroke can be caught — and one with no
    /// modifiers leaves Shift-Return to the field, where it still inserts a newline.
    ///
    /// On iOS it is the `onKeyPress` modifier that works and a key equivalent that would
    /// double up, so there this does nothing.
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
    /// A term, which opens the search field over the transcript with it already typed.
    public static var search: String?
    /// A message, which puts its quote chip above the field.
    public static var quote: String?
    /// Draws the "…" menu's Model choices as a popover over the toolbar. A screenshot needs
    /// them on screen and nothing on a simulator can open a real menu; the contents are the
    /// menu's own, not a copy of them.
    public static var modelMenu = false
    /// Puts the share extension's composer on screen. The app draws it only for a screenshot:
    /// nothing on a simulator can open a real share sheet on demand, and the composer is the
    /// part worth showing anyway.
    public static var share = false
    /// Draws every long message already unfolded, as tapping "Read more" leaves it. Nothing on
    /// a simulator taps a button on demand, and the two states are the picture worth having.
    public static var expanded = false
    /// Draws every bubble already pulled to its reply threshold, arrow filled. Same reason as
    /// ``modelMenu``: nothing on a simulator performs a swipe on demand, and the half-way point
    /// of the gesture is the part worth a picture. See ``View/swipeToReply(fromRight:action:)``.
    public static var swipe = false
    /// Opens the approval card's rule editor over the card. Same reason as ``modelMenu``:
    /// nothing on a simulator taps a button on demand, and the sheet is the part worth showing.
    public static var ruleEditor = false

    static func apply(
        search term: Binding<String>,
        searching: Binding<Bool>,
        quote chip: Binding<String?>
    ) {
        if let search {
            term.wrappedValue = search
            searching.wrappedValue = true
        }
        if let quote { chip.wrappedValue = quote }
    }
}

/// What is being replied to, inside the composer surface above the field: the quote itself, and
/// the way out of it. Dismissable, because changing your mind about a reply is not a mistake.
private struct ReplyChip: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            QuoteStrip(text: snippet(text))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: controlTarget, height: controlTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove quote")
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
        .disabled(total == 0)
        .accessibilityLabel(label)
    }
}

/// Shown between pressing Send and the first token arriving, so the thread is never silent
/// about the fact that something is happening.
private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.caption).foregroundStyle(.secondary)
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
        .accessibilityLabel("Jump to latest message")
    }
}

/// A thread nobody has said anything in yet: what this is for, and three ways to start.
private struct EmptyThreadView: View {
    let onPrompt: (String) -> Void

    private static let examples = [
        "Summarise my unread messages",
        "What's on my calendar tomorrow?",
        "Find the invoice I saved last week",
    ]

    /// The prompts go in the `actions` slot rather than in a stack under the view, which is
    /// what centres the whole group as one thing. They used to be a sibling, with the
    /// `ContentUnavailableView` pinned by `fixedSize` so it would stop taking the whole thread
    /// and pushing them onto the composer — and on the Mac that asked it for its ideal height,
    /// which is unbounded: the chat came out nineteen hundred points tall inside a five
    /// hundred point window, with the composer and everything under it clipped away.
    var body: some View {
        ContentUnavailableView {
            Label("Start a conversation", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Ask your Mac to look something up, keep track of it, or do it for you.")
        } actions: {
            VStack(spacing: 8) {
                ForEach(Self.examples, id: \.self) { example in
                    Button { onPrompt(example) } label: {
                        HStack(spacing: 8) {
                            Text(example)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .frame(maxWidth: 420)
        }
        .padding()
    }
}

/// A running turn lights the whole chat edge, including its navigation header. Reduce Motion
/// keeps the same state cue as a steady bezel instead of pulsing it.
private struct WorkingBezel: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Rectangle()
            .strokeBorder(
                Color.blue.opacity(active ? (bright || reduceMotion ? 0.9 : 0.3) : 0),
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
            .background(.quaternary)
    }
}

extension View {
    /// Search over the transcript, hidden until `presented` becomes true. iOS uses its navigation
    /// drawer; Mac uses the default toolbar placement.
    @ViewBuilder fileprivate func threadSearch(text: Binding<String>, presented: Binding<Bool>) -> some View {
        #if os(iOS)
            searchable(
                text: text,
                isPresented: presented,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Find in thread"
            )
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
