import Foundation

/// Every thread a client knows about: the connection, the events per thread, and whether the
/// runtime is reachable. Shared by both apps — what differs between them is the
/// ``ChatTransport`` handed in, the relay on the phone and the local socket on the Mac.
///
/// History is read from the ``ThreadCache`` first when there is one, so the phone opens and
/// reads offline; `sync_delta` fills in whatever happened since. The Mac passes no cache: the
/// thread logs on its own disk are the originals.
@MainActor
@Observable
public final class ChatModel {
    /// Every thread, the unsent draft included, newest first once a list has ordered them.
    public var threads: [ThreadSummary] { draft.map { [$0] + synced } ?? synced }
    /// The threads the runtime has told us about.
    private var synced: [ThreadSummary] = []
    /// The thread this device has started but not yet sent anything in, so the runtime has never
    /// heard of it. There is at most one: starting another replaces it.
    public private(set) var draft: ThreadSummary?
    /// Whether a `thread_list` has arrived yet, so an app can wait before deciding what to open.
    public private(set) var listed = false
    /// Events per thread id, oldest first.
    public private(set) var events: [String: [YorozuEvent]] = [:]
    public private(set) var state: TransportState = .connecting
    /// Starts pessimistic: the transport tells us the truth when it connects.
    public private(set) var ownerOnline = false
    public private(set) var failure: String?
    /// Action IDs already answered from this device, so the card stops offering buttons.
    public private(set) var answered: Set<String> = []
    /// The same for question cards, which are answered with a choice rather than a decision.
    public private(set) var answeredQuestions: Set<String> = []
    /// What this device chose for each answered action, so the card can say so afterwards.
    public private(set) var choices: [String: ApprovalAnswerData.Answer] = [:]
    /// One composer draft per thread, so switching threads does not lose what was typed.
    public var drafts: [String: String] = [:]
    /// The file staged in a thread's composer but not yet sent, alongside its draft text.
    /// At most one: the composer offers one attach button and replaces what it holds.
    public var attachments: [String: MessageAttachment] = [:]
    /// Threads with a turn in flight, so the composer offers Stop rather than Send.
    ///
    /// Set when this device sends, cleared by the agent message flagged `done` that ends the
    /// turn — or by pressing Stop, because an interrupted turn deliberately says nothing back.
    /// It is per-process and starts empty: a turn another device started is not ours to stop.
    public private(set) var generating: Set<String> = []
    /// Every device the runtime answers, newest list wins. Only the Mac's Settings draws these.
    public private(set) var devices: [DeviceInfo] = []
    /// Every model a thread can be put on, as the Mac has it configured. Arrives with the
    /// thread list; empty until then, which is a picker that offers only Default.
    public private(set) var models: [ModelOption] = []
    /// Messages typed with nowhere to send them, oldest first. Persisted, so a phone closed on
    /// the underground still has them when it comes back up. See ``OutboxItem``.
    public private(set) var outbox: [OutboxItem] = []
    /// Threads an agent reply landed in while they were not the one open. What the list's dots
    /// draw, and kept in the cache so closing the app does not mark everything read.
    public private(set) var unread: Set<String> = []
    /// The thread the user is looking at, set by whatever owns the navigation. A reply arriving
    /// here is read on arrival; a reply anywhere else raises a dot. Nil means none is open.
    public var openThread: String? {
        didSet { if let openThread { markRead(openThread) } }
    }

    /// Called once the transport can carry events. The iOS end-to-end harness drives its first
    /// message from here; the Mac app has no use for it.
    public var onPaired: (() -> Void)?
    /// Called whenever the runtime sends a new thread list.
    public var onThreads: (() -> Void)?
    /// Called whenever the runtime sends a new device list.
    public var onDevices: (() -> Void)?
    /// Called for every event kept in a thread, after it has been applied.
    public var onEvent: ((YorozuEvent) -> Void)?

    private let transport: any ChatTransport
    private let cache: ThreadCache?
    /// What this client tags the events it emits with.
    private let device: String
    private var started = false
    /// One flush at a time: the queue is sent in order, and two loops draining it would not be.
    private var flushing = false

    public init(transport: any ChatTransport, cache: ThreadCache? = nil, device: String = "phone") {
        self.transport = transport
        self.cache = cache
        self.device = device
        guard let cache else { return }
        synced = cache.threads()
        unread = cache.unread()
        outbox = Outbox.pruned(cache.outbox())
        for thread in synced { events[thread.id] = cache.events(threadId: thread.id) }
    }

    /// Connects and applies updates until the transport ends. Calling it twice does nothing.
    public func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            guard let stream = await self?.transport.connect() else { return }
            for await update in stream { self?.apply(update) }
        }
    }

    public func close() {
        Task { [transport] in await transport.close() }
    }

    /// Called when the app comes back to the foreground: a socket that dropped while it was
    /// suspended is re-dialled now instead of after the transport's backoff.
    public func reconnect() {
        Task { [transport] in await transport.reconnect() }
    }

    /// Sends what the composer holds — the typed text and any staged file — and empties it.
    public func send(in thread: ThreadSummary) {
        let text = (drafts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = attachments[thread.id]
        // A photo on its own is a message: only an empty composer is nothing to send.
        guard !text.isEmpty || attachment != nil else { return }
        drafts[thread.id] = ""
        attachments[thread.id] = nil
        send(text, in: thread.id, attachment: attachment)
    }

    public func send(_ text: String, in threadId: String, attachment: MessageAttachment? = nil) {
        // Decided once for the whole send: a thread created here and the message that creates it
        // must not take different routes, or the runtime is told about a message in a thread it
        // has never heard of.
        let queue = !canDeliver
        if let draft, draft.id == threadId {
            // A draft becomes real with its first message. The id is ours, so the message below
            // lands in the thread this `thread_create` is about to mint on the other end.
            deliver(
                event(.threadCreate(ThreadCreateData(title: nil)), in: threadId),
                queue: queue
            )
            // A model chosen in a chat that had not been sent in yet is held on the draft,
            // because there was no thread to set it on. This is that moment, and it goes
            // before the message so the first turn already runs on it.
            if let model = draft.model {
                deliver(event(.threadSetModel(ThreadSetModelData(model: model)), in: threadId), queue: queue)
            }
            self.draft = nil
            synced.insert(draft, at: 0)
        }
        let event = YorozuEvent(
            id: UUID().uuidString,
            threadId: threadId,
            ts: Int(Date().timeIntervalSince1970 * 1000),
            agentId: device,
            payload: .message(MessageData(role: .user, text: text, attachment: attachment))
        )
        // A queued message has started no turn: the composer stays a composer until the message
        // is actually on its way.
        if !queue { generating.insert(threadId) }
        upsert(event)
        deliver(event, queue: queue)
    }

    /// Whether an event sent now would actually reach the runtime. Anything else — still
    /// dialling, joined at the relay but not paired, or paired with the Mac asleep — is what
    /// the outbox is for.
    public var canDeliver: Bool { state == .paired && ownerOnline }

    /// What a bubble says about a message, or nil for one that went out normally.
    public func outboxStatus(of eventId: String) -> OutboxStatus? {
        outbox.first { $0.id == eventId }?.status
    }

    /// Sends a message the queue gave up on again, from the top: pressing "Not sent" is a fresh
    /// three tries, and one more wait if the Mac is still away.
    public func retry(_ eventId: String) {
        guard let index = outbox.firstIndex(where: { $0.id == eventId }) else { return }
        outbox[index].tries = 0
        saveOutbox()
        flush()
    }

    private func deliver(_ event: YorozuEvent, queue: Bool) {
        guard queue else { return emit(event) }
        outbox = Outbox.pruned(outbox + [OutboxItem(event: event)])
        saveOutbox()
    }

    /// Empties the queue, oldest first, and stops at the first message the transport refuses:
    /// the rest are behind it, and a thread read out of order is worse than one that arrives
    /// late. A refusal costs that message one of its three tries and the next reconnect tries
    /// again; one that has spent all three is stepped over rather than left blocking the queue,
    /// because it is waiting on the person now and not on the network.
    public func flush() {
        guard !flushing, canDeliver, !outbox.isEmpty else { return }
        flushing = true
        Task { [weak self] in
            while let self, self.canDeliver,
                let item = self.outbox.first(where: { $0.status == .queued })
            {
                do {
                    try await self.transport.send(item.event)
                    self.outbox.removeAll { $0.id == item.id }
                } catch {
                    self.bumpTries(of: item.id)
                    break
                }
            }
            self?.flushing = false
            self?.saveOutbox()
        }
    }

    private func bumpTries(of id: String) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox[index].tries += 1
    }

    private func saveOutbox() {
        outbox = Outbox.pruned(outbox)
        cache?.save(outbox: outbox)
    }

    /// Stops the turn running in a thread. The runtime cancels the agent and every agent it
    /// delegated to, and deliberately sends no reply back — so the composer is released here
    /// rather than waiting for a `done` that is never coming.
    public func interrupt(in threadId: String) {
        generating.remove(threadId)
        emit(.interrupt(InterruptData()), in: threadId)
    }

    /// Forgets one event on this device only: it stays in the runtime's thread log, and a
    /// device that syncs from scratch will see it again. Tidying a transcript, not deleting.
    public func delete(_ eventId: String, in threadId: String) {
        guard var thread = events[threadId] else { return }
        thread.removeAll { $0.id == eventId }
        events[threadId] = thread
        cache?.save(events: thread, threadId: threadId)
    }

    /// A thread that exists only on this device until its first message: nothing is sent until
    /// then, so backing out of it leaves nothing behind. Replaces any draft still unsent.
    @discardableResult
    public func newDraft() -> ThreadSummary {
        let thread = ThreadSummary(
            id: UUID().uuidString,
            title: "",
            archived: false,
            lastActivity: Date().timeIntervalSince1970 * 1000
        )
        draft = thread
        return thread
    }

    /// Throws away the draft when it is still the one named and still unsent. A draft that was
    /// sent in is a real thread by then and is not this one any more.
    public func discardDraft(_ threadId: String) {
        if draft?.id == threadId { draft = nil }
    }

    /// Creates a thread on the runtime straight away, title and all. Only the end-to-end harness
    /// wants this: what the apps do is start a ``newDraft()`` and let the first message create it.
    @discardableResult
    public func createThread(title: String = "") -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString
        emit(.threadCreate(ThreadCreateData(title: trimmed.isEmpty ? nil : trimmed)), in: id)
        return id
    }

    /// Renames a thread for good: a title the user typed is never auto-titled over.
    public func rename(_ thread: ThreadSummary, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != thread.title else { return }
        emit(.threadRename(ThreadRenameData(title: trimmed)), in: thread.id)
    }

    public func archive(_ thread: ThreadSummary) { setArchived(thread, true) }

    /// Archives a thread, or brings it back out of the archive.
    public func setArchived(_ thread: ThreadSummary, _ archived: Bool) {
        // An unsent draft is nowhere but here, so dropping it is the whole of archiving it —
        // and there is nothing to bring back afterwards.
        guard draft?.id != thread.id else {
            if archived { discardDraft(thread.id) }
            return
        }
        set(thread.id) { $0.archived = archived }
        emit(.threadArchive(ThreadArchiveData(archived: archived)), in: thread.id)
    }

    /// Pins a thread to the top of the list, or unpins it. A draft cannot be pinned: it does not
    /// exist anywhere the pin could be remembered.
    public func setPinned(_ thread: ThreadSummary, _ pinned: Bool) {
        guard draft?.id != thread.id else { return }
        set(thread.id) { $0.pinned = pinned }
        emit(.threadPin(ThreadPinData(pinned: pinned)), in: thread.id)
    }

    /// Runs this thread on one model rather than the Mac's configured chain: `model` is a spec
    /// from ``models``, and nil puts it back on the default. A thread nothing has been sent in
    /// yet keeps the choice on the draft — there is no thread on the Mac to set it on until the
    /// first message, which carries it along (see ``send(_:in:attachment:)``).
    public func setModel(_ thread: ThreadSummary, _ model: String?) {
        guard draft?.id != thread.id else {
            draft?.model = model
            return
        }
        set(thread.id) { $0.model = model }
        emit(.threadSetModel(ThreadSetModelData(model: model)), in: thread.id)
    }

    /// Applies a flag to the thread here and now, so the row moves under the swipe rather than a
    /// round trip later. Optimistic: the runtime's next `thread_list` is what finally decides.
    private func set(_ threadId: String, _ change: (inout ThreadSummary) -> Void) {
        guard let index = synced.firstIndex(where: { $0.id == threadId }) else { return }
        change(&synced[index])
    }

    /// Clears a thread's unread dot. Called for whichever thread is open, so reading is what
    /// marks it read.
    public func markRead(_ threadId: String) {
        guard unread.remove(threadId) != nil else { return }
        cache?.save(unread: unread)
    }

    /// Answers a pending approval card, in the thread the card was raised in. `Discuss` is
    /// answered too: the runtime keeps the action pending and sends a fresh card, with a new
    /// action ID, after it has explained itself.
    public func answer(_ actionId: String, in threadId: String, _ answer: ApprovalAnswerData.Answer) {
        answered.insert(actionId)
        choices[actionId] = answer
        emit(.approvalAnswer(ApprovalAnswerData(actionId: actionId, answer: answer)), in: threadId)
    }

    /// Answers a question the agent asked, in the thread it asked it in. The agent's `ask_user`
    /// call is suspended on this: until it arrives, or expires, the turn is parked.
    public func answerQuestion(_ questionId: String, in threadId: String, _ answer: String) {
        answeredQuestions.insert(questionId)
        emit(.questionAnswer(QuestionAnswerData(questionId: questionId, answer: answer)), in: threadId)
    }

    private func emit(_ payload: YorozuEvent.Payload, in threadId: String) {
        emit(event(payload, in: threadId))
    }

    /// An event from this device, stamped now.
    private func event(_ payload: YorozuEvent.Payload, in threadId: String) -> YorozuEvent {
        YorozuEvent(
            id: UUID().uuidString,
            threadId: threadId,
            ts: Int(Date().timeIntervalSince1970 * 1000),
            agentId: device,
            payload: payload
        )
    }

    private func emit(_ event: YorozuEvent) {
        Task { [transport] in try? await transport.send(event) }
    }

    /// Asks the runtime who is paired. It also pushes a fresh list whenever one comes or goes.
    public func requestDevices() {
        emit(.deviceList(DeviceListData(devices: [])), in: "")
    }

    /// Forgets a paired device, here and at the relay. Answered with a new list.
    public func removeDevice(_ pub: String) {
        emit(.deviceRemove(DeviceRemoveData(pub: pub)), in: "")
    }

    /// Asks for everything each thread has gained since the last event we hold.
    public func requestSync() {
        emit(
            .syncRequest(SyncRequestData(lastSeen: events.compactMapValues { $0.last?.id })),
            in: ""
        )
    }

    /// What a pull-to-refresh does: ask for a fresh thread list and every event we are behind on.
    ///
    /// The wait is the whole of the "async" here. Both answers arrive over the transport as
    /// ordinary events rather than as a reply to await, so the pull holds its spinner long enough
    /// to read as an action taken instead of blinking out before the frames land.
    public func refresh() async {
        emit(.threadList(ThreadListData(threads: [])), in: "")
        requestSync()
        try? await Task.sleep(for: .milliseconds(700))
    }

    private func apply(_ update: TransportUpdate) {
        switch update {
        case .state(let state):
            self.state = state
            if state == .paired {
                failure = nil
                requestSync()
                onPaired?()
                flush()
            }
        case .ownerOnline(let online):
            ownerOnline = online
            // The Mac waking up is the other half of "there is somewhere to send to".
            if online { flush() }
        case .event(let event):
            switch event.payload {
            case .threadList(let data):
                // Archived threads are kept: the phone's list draws them in a section of their
                // own, which is also the only place they can be brought back from.
                synced = data.threads
                listed = true
                cache?.save(threads: synced)
                onThreads?()
            case .syncDelta(let data):
                for event in data.events { upsert(event) }
            // What the model picker offers, sent with every thread list. Not a thread's event.
            case .modelList(let data):
                models = data.models
            // About the devices rather than in a thread, like the thread list above it.
            case .deviceList(let data):
                devices = data.devices
                onDevices?()
            default:
                upsert(event)
            }
        case .failed(let reason):
            failure = reason
        }
    }

    /// Every kind is kept, per thread, in arrival order: the thread draws the messages and the
    /// approval cards, and the thoughts, tool calls and results behind them are what the
    /// drill-down traces. It is also what the cache holds, so a relaunch redraws the same
    /// thread offline.
    ///
    /// Agent replies stream as repeated events under one id, each carrying the whole text so
    /// far, so the newest wins in place instead of appending a duplicate bubble.
    /// Test-only: drops a user message, a pending approval card and a running turn into a
    /// thread on this device alone, so the card and the Stop state can be screenshotted.
    /// Test-only: a thread list spread across every dated section, so the headings can be
    /// screenshotted without two days of history on the device.
    public func previewThreads() {
        let now = Date().timeIntervalSince1970 * 1000
        let day = 24.0 * 60 * 60 * 1000
        func thread(_ title: String, _ last: String, _ agoDays: Double, pinned: Bool = false)
            -> ThreadSummary
        {
            ThreadSummary(
                id: title,
                title: title,
                archived: false,
                lastActivity: now - agoDays * day,
                lastMessage: last,
                pinned: pinned
            )
        }
        synced = [
            thread("Weeknight dinners", "Roast chicken, then stock on Sunday.", 0.02, pinned: true),
            thread("Invoices", "Found the July one in Downloads.", 0.05),
            thread("Kyoto in April", "Booked the 9:05 to Kyoto.", 0.2),
            thread("Standup notes", "Summarised yesterday's thread.", 1.1),
            thread("Bike service", "Rescheduled for Thursday.", 3.2),
            thread("Tax return", "Filed — the receipt is in Documents.", 40),
        ]
        listed = true
    }

    /// Test-only: the models a Mac with two providers configured would publish, and a thread
    /// already put on the second of them — which is what a screenshot of the picker is about.
    public func previewModels(in threadId: String) {
        models = [
            ModelOption(id: "claude/claude-opus-5", label: "claude-opus-5", providerLabel: "Claude"),
            ModelOption(id: "claude/claude-sonnet-5", label: "claude-sonnet-5", providerLabel: "Claude"),
            ModelOption(id: "codex/gpt-5.6", label: "gpt-5.6", providerLabel: "Codex"),
        ]
        set(threadId) { $0.model = "claude/claude-sonnet-5" }
    }

    /// Test-only: one message waiting for the Mac and one the outbox gave up on, so the two
    /// captions can be screenshotted with no relay in the picture.
    public func previewQueued(in threadId: String) {
        upsert(
            YorozuEvent(
                id: "showcase-reply", threadId: threadId, ts: Int(Date().timeIntervalSince1970 * 1000) - 90_000,
                agentId: "main",
                payload: .message(MessageData(role: .agent, text: "Roast chicken it is — I'll put the stock on the list for Sunday.", done: true))
            )
        )
        for (id, text, tries) in [
            ("showcase-queued", "Also add potatoes and a lemon", 0),
            ("showcase-failed", "And check what time the butcher closes", Outbox.maxTries),
        ] {
            var event = self.event(.message(MessageData(role: .user, text: text)), in: threadId)
            event.id = id
            upsert(event)
            outbox.append(OutboxItem(event: event, tries: tries))
        }
    }

    /// Test-only: a reply with a bare link in it, for the preview row.
    public func previewLink(in threadId: String) {
        upsert(
            YorozuEvent(
                id: "showcase-link", threadId: threadId, ts: Int(Date().timeIntervalSince1970 * 1000),
                agentId: "main",
                payload: .message(MessageData(
                    role: .agent,
                    text: "The recipe you saved is here: https://cooking.example.com/roast-chicken — it wants a 20 minute rest.",
                    done: true
                ))
            )
        )
    }

    public func previewApproval(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(id: "showcase-user", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(role: .user, text: "Clean up the old screenshots on my Desktop"))))
        upsert(YorozuEvent(id: "showcase-card", threadId: threadId, ts: now + 1, agentId: "main",
            payload: .approvalCard(ApprovalCardData(
                actionId: "showcase", actionClass: "run-command",
                target: "rm ~/Desktop/Screenshot\\ 2026-09-*.png"))))
        generating.insert(threadId)
    }

    /// Test-only, alongside ``previewApproval``: a short finished conversation to search, quote
    /// and read in, so the screenshots have a thread rather than an empty one.
    public func previewChat(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(id: "showcase-ask", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(role: .user, text: "Did we ever pay the Kitanoya invoice?"))))
        upsert(YorozuEvent(id: "showcase-reply", threadId: threadId, ts: now + 1, agentId: "main",
            payload: .message(MessageData(role: .agent, text: Self.previewReply, done: true))))
        upsert(YorozuEvent(id: "showcase-thanks", threadId: threadId, ts: now + 2, agentId: device,
            payload: .message(MessageData(role: .user, text: "Perfect. Remind me before the next one."))))
    }

    private static let previewReply = """
        Yes — the **Kitanoya invoice** was paid on 3 March.

        | Invoice | Date | Amount | Status |
        | --- | --- | --- | --- |
        | KTN-0148 | 3 Mar | ¥48,000 | Paid |
        | KTN-0151 | 2 Apr | ¥12,400 | Due |

        The March invoice cleared from the Sumitomo account the same afternoon it arrived, and \
        the receipt is filed under Documents/Invoices/2026. The April invoice is still open: it \
        was issued on the second and the terms on it are thirty days, so it falls due at the end \
        of the month. Nothing has been scheduled for it yet.

        A few other things worth knowing about that account:

        - Every Kitanoya invoice since January has arrived by email rather than by post, which \
          is why none of them are in the paper folder you checked.
        - The amounts have crept up about eight percent since the autumn, all of it on the \
          delivery line rather than on the goods themselves.
        - Two invoices last year were paid twice, in June and in September, and both were \
          refunded within the fortnight — so the account is square, but it is worth a glance \
          before each payment goes out.

        I can set a reminder for the twenty-eighth, a few days before the April invoice is due, \
        and put the payment in front of you then rather than doing it quietly.
        """

    private func upsert(_ event: YorozuEvent) {
        var thread = events[event.threadId] ?? []
        if let index = thread.firstIndex(where: { $0.id == event.id }) {
            thread[index] = event
        } else {
            thread.append(event)
        }
        events[event.threadId] = thread
        // The agent's last message ends the turn, whether it streamed or arrived whole.
        if case .message(let data) = event.payload, data.role == .agent, data.done == true,
            event.parentAgentId == nil
        {
            generating.remove(event.threadId)
        }
        cache?.save(events: thread, threadId: event.threadId)
        // A reply that lands in a thread nobody is looking at is what a dot is for. Streaming
        // replaces one event in place, so a reply raises the dot once rather than per chunk.
        if case .message(let data) = event.payload, data.role == .agent,
            event.threadId != openThread, unread.insert(event.threadId).inserted
        {
            cache?.save(unread: unread)
        }
        onEvent?(event)
    }

    /// A thread as a Markdown transcript, from whatever this device holds of it. See
    /// ``threadMarkdown(thread:events:now:locale:timeZone:)``.
    public func markdown(of thread: ThreadSummary) -> String {
        threadMarkdown(thread: thread, events: events[thread.id] ?? [])
    }

    /// The thread's title as a list would draw it, for anything that has only an id. Falls back
    /// to the id itself.
    public func title(of threadId: String) -> String {
        threads.first { $0.id == threadId }?.displayTitle ?? threadId
    }
}
