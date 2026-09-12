import SwiftUI

/// One thread's messages, shared by both apps: the phone pushes it from ``ThreadListView``, the
/// Mac shows it as the detail half of its split view. Either way it has to sit inside a
/// navigation stack, which is what the trace drill-down pushes onto.
public struct ChatView: View {
    public let model: ChatModel
    public let thread: ThreadSummary
    /// Shown while the runtime is unreachable. The two apps lose it differently: the phone
    /// queues what is typed and sends it when the Mac is back, the Mac's sidecar is simply not
    /// running yet.
    public let offlineNotice: String

    /// Whether the reader is already at the newest message. Only then does a new one scroll the
    /// thread — pulling someone away from what they were reading is the thing to avoid.
    @State private var atBottom = true
    /// Bumped on every send, so the haptic fires per send rather than per keystroke.
    @State private var sends = 0
    /// Id of the reply whose first token just landed, which is the moment worth a tap.
    @State private var replyStarted: String?
    @State private var attachmentTooLarge = false
    /// Dictation is per-open-thread: leaving the thread tears the audio down with the view.
    @State private var dictation = Dictation()
    /// The message being replied to, quoted above the field until it is sent or dismissed.
    @State private var replyQuote: String?
    @State private var searching = false
    /// Screenshot only: draws the model menu's own contents as a popover, because nothing on a
    /// simulator can open a real menu. See ``ChatShowcase``.
    @State private var modelShowcase = ChatShowcase.modelMenu
    @State private var search = ""
    /// Which hit the arrows are on. Reset whenever the term changes.
    @State private var hit = 0

    /// Anchor for "scroll to the end". A zero-height view after the last row rather than the
    /// row itself: scrolling to the last row leaves its bottom edge under the composer.
    private static let bottomAnchor = "yorozu.chat.bottom"

    public init(
        model: ChatModel,
        thread: ThreadSummary,
        offlineNotice: String = "Mac offline — what you send waits on this phone until it's back."
    ) {
        self.model = model
        self.thread = thread
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

    private var attachment: Binding<MessageAttachment?> {
        Binding(get: { model.attachments[thread.id] }, set: { model.attachments[thread.id] = $0 })
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
        // Inside the stack: a trace pushed from here keeps streaming this thread.
        .agentTraceDestination { events }
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
            // iOS only: there the search field is hidden until something asks for it, and this
            // is the thing that asks. The Mac's toolbar shows the field itself, so a magnifier
            // beside it would be a second control for the one already on screen — ⌘F focuses
            // it instead, through the Edit menu. See ``ChatCommands``.
            #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Find in thread", systemImage: "magnifyingglass") { searching = true }
                }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    ExportThreadButton(title: thread.displayTitle) {
                        threadMarkdown(thread: thread, events: events)
                    }
                    // Nothing to choose between until the runtime has said what it has.
                    if !model.models.isEmpty {
                        Menu("Model", systemImage: "cpu") { modelPicker }
                    }
                }
            }
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
        // mid-sentence and ended dictation mid-word, with nothing on screen having changed.
        // Closing the window is handled where the window is — see ``ChatWindowView``.
        .onChange(of: thread.id) { _, _ in
            Speaker.shared.stop()
            dictation.stop()
        }
        #if os(iOS)
            .onDisappear {
                Speaker.shared.stop()
                dictation.stop()
            }
        #endif
        // Keyed on the thread: the Mac's split view builds its detail more than once while the
        // window and the thread list settle, and a plain `.task` left the seeded state on
        // whichever copy ran first rather than on the one on screen.
        .task(id: thread.id) {
            ChatShowcase.apply(dictation: dictation, search: $search, searching: $searching, quote: $replyQuote)
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
        .alert("That file is too large", isPresented: $attachmentTooLarge) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Attachments are limited to 5 MB.")
        }
        .alert("Dictation needs permission", isPresented: $dictation.denied) {
            Button("OK", role: .cancel) {}
        } message: {
            #if os(macOS)
                Text("Allow microphone access and speech recognition in System Settings to dictate.")
            #else
                Text("Allow microphone access and speech recognition in Settings to dictate.")
            #endif
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

    /// What the caption under the title says, or nil for a thread on the default chain. A spec
    /// the Mac no longer offers still gets a caption: the thread really is set to it, and
    /// saying so is how the user finds out it wants changing.
    private var modelCaption: String? {
        guard let spec = thread.model else { return nil }
        return model.models.first { $0.id == spec }?.menuLabel ?? spec
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // A delegation collapses to one card where it started and what the
                    // specialist did is behind it; the main agent's own tool use is shown
                    // here, grouped, where it happened.
                    ForEach(rows) { row in
                        switch row {
                        case .message(let event):
                            if case .message(let data) = event.payload {
                                MessageBubble(
                                    id: event.id,
                                    data: data,
                                    streaming: event.id == streamingId,
                                    // Set only while the message is still in the outbox, which
                                    // is what earns it a "Queued" or "Not sent" caption.
                                    status: model.outboxStatus(of: event.id),
                                    onRetry: data.role == .user ? { retry(data) } : nil,
                                    onDelete: { model.delete(event.id, in: thread.id) },
                                    onReply: { replyQuote = $0 },
                                    onResend: { model.retry(event.id) }
                                )
                                .id(event.id)
                            }
                        case .tools(let activities):
                            // No `.id` of its own: nothing scrolls to a tool row, and the row
                            // is already keyed by `ChatRow.id` in the `ForEach` above.
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
            // Every frame of a streaming reply lands here, not just every message: the text of
            // the last event grows in place, so its id alone would never change.
            .onChange(of: ChangeStamp(events: events)) { _, _ in
                noteReplyStart()
                guard atBottom else { return }
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                // Not while searching: the arrows are already moving the thread about, and a
                // pill offering to jump somewhere else would be arguing with them.
                if !atBottom, search.isEmpty {
                    ScrollToBottomPill {
                        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: atBottom)
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
            if let staged = attachment.wrappedValue {
                StagedAttachment(attachment: staged) { attachment.wrappedValue = nil }
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
                    onPick: { attachment.wrappedValue = $0 },
                    onTooLarge: { attachmentTooLarge = true }
                )
                .disabled(generating)
                TextField(dictation.listening ? "" : "Message Yorozu", text: draft, axis: .vertical)
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
                    // While listening, the level takes the placeholder's place: the field is
                    // already saying "type here", and what it needs to say now is "I can hear
                    // you". Gone the moment there are words to show instead.
                    .overlay(alignment: .leading) {
                        if dictation.listening, draft.wrappedValue.isEmpty {
                            LevelMeter(levels: dictation.levels).allowsHitTesting(false)
                        }
                    }
                // Hidden mid-turn: there is nothing to dictate into until the turn is over.
                if !generating, dictation.available {
                    MicButton(dictation: dictation, draft: draft)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                sendOrStop
                    .padding(.trailing, 6)
                    .frame(height: controlTarget)
            }
        }
        .background(fieldBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        // While a turn runs the outline itself breathes in the accent: the field is the one
        // thing on screen that changes job, so it is the one thing that says "working".
        // Listening earns the same breathing outline a running turn does: in both, the field
        // is doing something rather than waiting.
        .overlay(WorkingOutline(active: generating || dictation.listening))
        .animation(.easeOut(duration: 0.18), value: attachment.wrappedValue != nil)
        .animation(.easeOut(duration: 0.18), value: generating)
        .animation(.easeOut(duration: 0.18), value: replyQuote != nil)
        .animation(.easeOut(duration: 0.18), value: dictation.listening)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .composerBackground()
    }

    private var fieldBackground: Color {
        #if os(iOS)
            Color(.secondarySystemGroupedBackground)
        #else
            Color(nsColor: .textBackgroundColor)
        #endif
    }

    /// One slot, two states. Send is a filled accent circle only once there is something to
    /// send; before that it is a hollow outline, so the eye is not pulled to a dead control.
    /// Stop replaces it with a filled square in the same place: same size, same spot, new job.
    @ViewBuilder private var sendOrStop: some View {
        if generating {
            Button {
                model.interrupt(in: thread.id)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.footnote.weight(.bold))
                    // `.background` against `Color.primary`, not white against it: primary is
                    // white in the dark, and a white glyph on it was an empty circle.
                    .foregroundStyle(.background)
                    .frame(width: sendCircle, height: sendCircle)
                    .background(Color.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .macKey(.escape)
            .accessibilityLabel("Stop")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
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
            .disabled(!canSend)
            .macKey(.return)
            .accessibilityLabel("Send")
            .animation(.easeOut(duration: 0.15), value: canSend)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    private var canSend: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || attachment.wrappedValue != nil
    }

    private func send() {
        guard canSend else { return }
        // The quote goes into the message itself, as a blockquote, so a reply is one ordinary
        // message and no client, cache or runtime has to learn a new field for it.
        if let quote = replyQuote {
            draft.wrappedValue = quotedMessage(quoting: quote, body: draft.wrappedValue)
            replyQuote = nil
        }
        dictation.stop()
        model.send(in: thread)
        sends += 1
        // Sending is always a jump to the end: it is your own message, and you meant it.
        atBottom = true
    }

    /// Sends the same thing again, as a new message. The original stays where it is — a
    /// transcript that quietly rewrote itself would not be one.
    private func retry(_ data: MessageData) {
        model.send(data.text, in: thread.id, attachment: data.attachment)
        sends += 1
        atBottom = true
    }

    /// Fires the reply haptic once per reply, on the event that first carries agent text.
    private func noteReplyStart() {
        guard let streamingId else { return }
        if replyStarted != streamingId { replyStarted = streamingId }
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
    /// A level trace, which puts the composer into its listening state.
    public static var dictation: [Double]?
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
    /// Opens the approval card's rule editor over the card. Same reason as ``modelMenu``:
    /// nothing on a simulator taps a button on demand, and the sheet is the part worth showing.
    public static var ruleEditor = false

    static func apply(
        dictation engine: Dictation,
        search term: Binding<String>,
        searching: Binding<Bool>,
        quote chip: Binding<String?>
    ) {
        if let levels = dictation { engine.preview(levels: levels) }
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

/// The composer's outline. Quiet at rest; while a turn runs it settles into the accent and
/// breathes, which reads as activity without adding a spinner to the field. Reduce Motion
/// gets the steady accent outline with no pulse.
private struct WorkingOutline: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                active ? AnyShapeStyle(Color.accentColor.opacity(bright || reduceMotion ? 0.9 : 0.35))
                       : AnyShapeStyle(.separator.opacity(0.6)),
                lineWidth: active ? 1.5 : 1
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
    /// Search over the transcript, in the navigation bar rather than wherever the platform
    /// would otherwise put it. The Mac has no drawer to put it in and needs no `#available`
    /// either: it takes the default placement, which is its own toolbar.
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

    /// The composer floats over the thread scrolling under it. Liquid Glass where the OS has
    /// it, and the same material bar it has always been where it does not.
    @ViewBuilder fileprivate func composerBackground() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            background(.bar).glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            background(.bar)
        }
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
