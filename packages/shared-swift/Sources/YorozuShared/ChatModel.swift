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

    public init(transport: any ChatTransport, cache: ThreadCache? = nil, device: String = "phone") {
        self.transport = transport
        self.cache = cache
        self.device = device
        guard let cache else { return }
        synced = cache.threads()
        unread = cache.unread()
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
        if let draft, draft.id == threadId {
            // A draft becomes real with its first message. The id is ours, so the message below
            // lands in the thread this `thread_create` is about to mint on the other end.
            emit(.threadCreate(ThreadCreateData(title: nil)), in: threadId)
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
        generating.insert(threadId)
        upsert(event)
        emit(event)
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
        emit(
            YorozuEvent(
                id: UUID().uuidString,
                threadId: threadId,
                ts: Int(Date().timeIntervalSince1970 * 1000),
                agentId: device,
                payload: payload
            )
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
            }
        case .ownerOnline(let online):
            ownerOnline = online
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

    /// The thread's title as a list would draw it, for anything that has only an id. Falls back
    /// to the id itself.
    public func title(of threadId: String) -> String {
        threads.first { $0.id == threadId }?.displayTitle ?? threadId
    }
}
