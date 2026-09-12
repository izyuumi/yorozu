import SwiftUI

/// One thread's messages, shared by both apps: the phone pushes it from ``ThreadListView``, the
/// Mac shows it as the detail half of its split view. Either way it has to sit inside a
/// navigation stack, which is what the trace drill-down pushes onto.
public struct ChatView: View {
    public let model: ChatModel
    public let thread: ThreadSummary
    /// Shown while the runtime is unreachable. The two apps lose it differently: the phone's
    /// frames are buffered by the relay, the Mac's sidecar is simply not running yet.
    public let offlineNotice: String

    /// Whether the reader is already at the newest message. Only then does a new one scroll the
    /// thread — pulling someone away from what they were reading is the thing to avoid.
    @State private var atBottom = true
    /// Bumped on every send, so the haptic fires per send rather than per keystroke.
    @State private var sends = 0
    /// Id of the reply whose first token just landed, which is the moment worth a tap.
    @State private var replyStarted: String?
    @State private var attachmentTooLarge = false

    /// Anchor for "scroll to the end". A zero-height view after the last row rather than the
    /// row itself: scrolling to the last row leaves its bottom edge under the composer.
    private static let bottomAnchor = "yorozu.chat.bottom"

    public init(
        model: ChatModel,
        thread: ThreadSummary,
        offlineNotice: String = "Mac offline — messages are held by the relay until it returns."
    ) {
        self.model = model
        self.thread = thread
        self.offlineNotice = offlineNotice
    }

    private var events: [YorozuEvent] { model.events[thread.id] ?? [] }

    private var rows: [ChatRow] { chatRows(from: events) }

    private var generating: Bool { model.generating.contains(thread.id) }

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
                                    data: data,
                                    streaming: event.id == streamingId,
                                    onRetry: data.role == .user ? { retry(data) } : nil,
                                    onDelete: { model.delete(event.id, in: thread.id) }
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
                                ) { model.answer(card.actionId, in: thread.id, $0) }
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
                if !atBottom {
                    ScrollToBottomPill {
                        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: atBottom)
        }
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
            HStack(alignment: .bottom, spacing: 4) {
                AttachButton(
                    onPick: { attachment.wrappedValue = $0 },
                    onTooLarge: { attachmentTooLarge = true }
                )
                .disabled(generating)
                TextField("Message Yorozu", text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    // Hardware keyboards only, which is the whole point: on a paired iPad or a
                    // Mac, Return sends and Shift-Return keeps typing. The on-screen keyboard
                    // never gets here, so its Return still inserts a newline.
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        send()
                        return .handled
                    }
                    .accessibilityLabel("Message")
                sendOrStop
                    .padding(.trailing, 6)
                    .frame(height: 44)
            }
        }
        .background(fieldBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        // While a turn runs the outline itself breathes in the accent: the field is the one
        // thing on screen that changes job, so it is the one thing that says "working".
        .overlay(WorkingOutline(active: generating))
        .animation(.easeOut(duration: 0.18), value: attachment.wrappedValue != nil)
        .animation(.easeOut(duration: 0.18), value: generating)
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
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.accentColor : Color.clear, in: Circle())
                    .overlay(Circle().strokeBorder(.separator, lineWidth: canSend ? 0 : 1.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
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

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            ContentUnavailableView {
                Label("Start a conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Ask your Mac to look something up, keep track of it, or do it for you.")
            }
            // Left to itself it takes the whole thread and pushes the prompts onto the
            // composer; sized to its content, the two centre together as one group.
            .fixedSize(horizontal: false, vertical: true)
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
            Spacer(minLength: 0)
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
