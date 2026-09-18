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
    /// Advances after a complete sync response. Notification navigation uses this to tell
    /// "events have not arrived yet" from "refresh finished and there is no message anchor".
    public private(set) var syncRevision = 0
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
    /// The choice made on this device, so a resolved question keeps its answer visible.
    public private(set) var questionChoices: [String: String] = [:]
    /// Proposals this device has reviewed or waved away, so the card stops offering buttons.
    public private(set) var handledProposals: Set<String> = []
    /// The stored approval rules, as the runtime last listed them. What the Rules screens draw.
    public private(set) var rules: [ApprovalRule] = []
    /// Global bypass reported by the Mac runtime. Off until explicitly reported otherwise.
    public private(set) var yoloMode = false
    /// What this device chose for each answered action, so the card can say so afterwards.
    public private(set) var choices: [String: ApprovalAnswerData.Answer] = [:]
    /// One composer draft per thread, so switching threads does not lose what was typed.
    public var drafts: [String: String] = [:]
    /// Files staged in each thread's composer but not yet sent, alongside its draft text.
    public var attachments: [String: [MessageAttachment]] = [:]
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
    /// The thread the user is looking at, set by whatever owns the navigation: the top of the
    /// phone's path, or the Mac's sidebar selection. Nil means none is open.
    public var openThread: String? {
        didSet { if openThread != oldValue { reportRead() } }
    }
    /// Whether this device is actually in front of somebody: the app is active, and on the Mac
    /// the chat window is the key window as well. Set by whichever app owns the scene.
    ///
    /// The other half of "genuinely reading". A thread left open on a phone in a pocket, or in
    /// a Mac window sitting behind everything else, is not being read by anyone — and used to
    /// mark every reply that landed in it read regardless, which is the bug this replaced.
    public var foreground = false {
        didSet { if foreground != oldValue { reportRead() } }
    }
    /// Pending debounced read report. A reply streams as many events under one id, so the
    /// report waits for it to settle rather than going out per chunk.
    private var readReport: Task<Void, Never>?
    /// Optimistic read marks not yet reflected by a runtime thread list. Without this merge, a
    /// list already in flight can briefly resurrect an unread dot after its thread opens.
    private var pendingReads: [String: Double] = [:]

    /// Called once the transport can carry events. The iOS end-to-end harness drives its first
    /// message from here; the Mac app has no use for it.
    public var onPaired: (() -> Void)?
    /// Called whenever the runtime sends a new thread list.
    public var onThreads: (() -> Void)?
    /// Called whenever the runtime sends a new device list.
    public var onDevices: (() -> Void)?
    /// Called whenever the runtime sends a new rule list.
    public var onRules: (() -> Void)?
    /// Called for every event kept in a thread, after it has been applied.
    public var onEvent: ((YorozuEvent) -> Void)?

    private let transport: any ChatTransport
    private let cache: ThreadCache?
    /// What this client tags the events it emits with.
    private let device: String
    private var started = false
    /// How many `sync_delta`s have been applied, which is what a background drain waits on.
    private var deltas = 0
    /// One flush at a time: the queue is sent in order, and two loops draining it would not be.
    private var flushing = false
    /// Direct sends share one tail so events finish on the wire in emission order. Starting one
    /// unstructured task per event let a message overtake its thread creation — or the relay's
    /// pairing hello — when URLSession resumed concurrent sends out of order.
    private var emitter: Task<Void, Never>?
    /// Latest unfinished agent event per message. Providers can emit faster than SwiftUI can
    /// lay out growing text; one model mutation per display slice keeps the UI responsive while
    /// the final event still lands immediately and losslessly.
    private var pendingStreamEvents: [String: YorozuEvent] = [:]
    private var streamFrame: Task<Void, Never>?

    public init(transport: any ChatTransport, cache: ThreadCache? = nil, device: String = "phone") {
        self.transport = transport
        self.cache = cache
        self.device = device
        guard let cache else { return }
        synced = cache.threads()
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

    /// Woken by a silent push with the app suspended: dial, wait for the runtime's answer to
    /// land, and hang up again. Returns whether anything actually arrived.
    ///
    /// Nothing is read out of the push — it carries nothing to read. The catching up is the
    /// ordinary one: connecting asks for a sync, the delta comes back as the events it always
    /// does, and the thread cache is moved by those rather than by
    /// anything the relay claimed. The relay could not have told us more if it wanted to.
    ///
    /// The socket is closed before returning. iOS gives a woken app seconds, and an app still
    /// holding one when its time runs out is suspended mid-connection rather than gracefully;
    /// the next foreground calls ``start()`` again, which dials afresh.
    @discardableResult
    public func drain(timeout: Duration = .seconds(20)) async -> Bool {
        let before = deltas
        // Either a first dial or a nudge past the backoff, depending on what the suspension
        // left behind.
        if started { reconnect() } else { start() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while deltas == before, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        close()
        // The stream is finished, so the next foreground has to start a new one rather than
        // reconnect a transport that has already hung up.
        started = false
        return deltas > before
    }

    /// Answers an approval from a notification button, with the app not running: dial, find
    /// the card the push named, send the answer, wait for it to leave, and hang up.
    ///
    /// The push carries only an opaque reference to the card event, so the card itself has to
    /// be here — from the cache, or from the sync that connecting asks for. Returns false when
    /// it never turns up, in which case the card stays unanswered and the app shows it.
    @discardableResult
    public func answerFromNotification(
        eventRef: String,
        _ answer: ApprovalAnswerData.Answer,
        timeout: Duration = .seconds(20)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        if started { reconnect() } else { start() }
        while state != .paired, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Not in the cache: connecting asked for a sync, so give the delta a moment to land.
        let before = deltas
        while approvalCard(eventRef: eventRef) == nil, deltas == before, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        defer {
            close()
            started = false
        }
        guard state == .paired, let (threadId, card) = approvalCard(eventRef: eventRef) else { return false }
        self.answer(card.actionId, in: threadId, answer)
        // The send is queued behind everything before it; wait for the queue to drain.
        await emitter?.value
        return true
    }

    /// The approval card whose event id the push referenced, wherever it is.
    private func approvalCard(eventRef: String) -> (String, ApprovalCardData)? {
        for (threadId, list) in events {
            for event in list where YorozuCrypto.threadRef(event.id) == eventRef {
                if case .approvalCard(let card) = event.payload { return (threadId, card) }
            }
        }
        return nil
    }

    /// Sends what the composer holds — the typed text and any staged file — and empties it.
    public func send(in thread: ThreadSummary) {
        let text = (drafts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = attachments[thread.id] ?? []
        // Files on their own are a message: only an empty composer is nothing to send.
        guard !text.isEmpty || !attachments.isEmpty else { return }
        drafts[thread.id] = ""
        self.attachments[thread.id] = nil
        send(text, in: thread.id, attachments: attachments)
    }

    public func send(_ text: String, in threadId: String, attachment: MessageAttachment? = nil) {
        send(text, in: threadId, attachments: attachment.map { [$0] } ?? [])
    }

    public func send(_ text: String, in threadId: String, attachments: [MessageAttachment]) {
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
            if let effort = draft.effort {
                deliver(event(.threadSetEffort(ThreadSetEffortData(effort: effort)), in: threadId), queue: queue)
            }
            self.draft = nil
            synced.insert(draft, at: 0)
        }
        let event = YorozuEvent(
            id: UUID().uuidString,
            threadId: threadId,
            ts: Int(Date().timeIntervalSince1970 * 1000),
            agentId: device,
            payload: .message(MessageData(role: .user, text: text, attachments: attachments))
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

    public func reactions(to messageId: String, in threadId: String) -> [MessageReaction] {
        messageReactions(in: events[threadId] ?? [], to: messageId, selectedBy: device)
    }

    public func reactions(in threadId: String) -> [String: [MessageReaction]] {
        messageReactionsByMessage(in: events[threadId] ?? [], selectedBy: device)
    }

    public func react(to messageId: String, with emoji: String, in threadId: String) {
        let remove = reactions(to: messageId, in: threadId).contains { $0.emoji == emoji && $0.selected }
        let reaction = event(.reaction(ReactionData(messageId: messageId, emoji: emoji, remove: remove)), in: threadId)
        upsert(reaction)
        deliver(reaction, queue: !canDeliver)
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
        // Unlike a cosmetic local toggle, archive changes canonical thread state. Keep the
        // exact request until transport sends it; a refused socket must not silently undo
        // the user's action on the next thread list.
        let request = event(.threadArchive(ThreadArchiveData(archived: archived)), in: thread.id)
        outbox = Outbox.pruned(outbox + [OutboxItem(event: request)])
        saveOutbox()
        flush()
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

    /// Sets how much reasoning this thread requests, or returns it to the provider default.
    /// Drafts keep the choice locally until their first message creates them on the runtime.
    public func setEffort(_ thread: ThreadSummary, _ effort: ReasoningEffort?) {
        guard draft?.id != thread.id else {
            draft?.effort = effort
            return
        }
        set(thread.id) { $0.effort = effort }
        emit(.threadSetEffort(ThreadSetEffortData(effort: effort)), in: thread.id)
    }

    /// Applies a flag to the thread here and now, so the row moves under the swipe rather than a
    /// round trip later. Optimistic: the runtime's next `thread_list` is what finally decides.
    private func set(_ threadId: String, _ change: (inout ThreadSummary) -> Void) {
        guard let index = synced.firstIndex(where: { $0.id == threadId }) else { return }
        change(&synced[index])
    }

    /// Threads with something in them nobody has read yet, on any device. What the app icon's
    /// badge counts, and drawn from the runtime's two timestamps rather than from anything this
    /// device happened to witness — see ``ThreadSummary/isUnread``.
    public var unreadCount: Int { threads.filter(\.isUnread).count }

    /// Whether `threadId` is genuinely being read here, right now: it is the thread on screen
    /// *and* the app is in the foreground. Both halves matter, and nothing is ever reported
    /// read without both — see ``foreground``.
    public func isReading(_ threadId: String) -> Bool {
        foreground && openThread == threadId
    }

    /// Resolves a notification's opaque thread reference locally, then applies the same
    /// foreground-and-visible rule. The relay never learns the underlying thread id.
    public func isReading(threadRef: String) -> Bool {
        guard let thread = threads.first(where: { YorozuCrypto.threadRef($0.id) == threadRef })
        else { return false }
        return isReading(thread.id)
    }

    /// Reports the open thread read, if it is in fact being read. Called on entering a thread,
    /// on the app becoming active with one open, and — debounced — when a reply lands in it.
    private func reportRead() {
        // A draft exists on this device alone: there is no thread on the runtime to mark.
        guard let openThread, openThread != draft?.id, isReading(openThread) else { return }
        markRead(openThread)
    }

    /// Tells the runtime `threadId` has been read, up to now.
    public func markRead(_ threadId: String) {
        send(read: threadId, at: Date().timeIntervalSince1970 * 1000)
    }

    public func markAllRead() {
        for thread in threads where thread.isUnread { markRead(thread.id) }
    }

    /// "Mark as unread": puts the mark just behind the newest reply, which is the one place it
    /// can sit and still leave the thread unread. A thread the agent has never spoken in has
    /// nothing to be unread about. ``ThreadReadData/reset`` is what lets it move backwards.
    public func markUnread(_ thread: ThreadSummary) {
        guard let lastAgentAt = thread.lastAgentAt else { return }
        send(read: thread.id, at: lastAgentAt - 1, reset: true)
    }

    /// The dot is dropped here as well as on the runtime's answering `thread_list`, so it goes
    /// the moment the thread opens rather than a round trip later.
    private func send(read threadId: String, at: Double, reset: Bool? = nil) {
        readReport?.cancel()
        if reset == true { pendingReads[threadId] = nil } else { pendingReads[threadId] = at }
        set(threadId) { $0.lastReadAt = at }
        emit(.threadRead(ThreadReadData(at: at, reset: reset)), in: threadId)
    }

    /// A reply that lands in the thread being read is read as it lands — after a moment, so a
    /// streaming reply reports once when it settles rather than on every chunk.
    private func reportReadSoon() {
        readReport?.cancel()
        readReport = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.reportRead()
        }
    }

    /// Answers a pending approval card, in the thread the card was raised in. `Discuss` is
    /// answered too: the runtime keeps the action pending and sends a fresh card, with a new
    /// action ID, after it has explained itself.
    public func answer(
        _ actionId: String,
        in threadId: String,
        _ answer: ApprovalAnswerData.Answer,
        rule: ApprovalRule? = nil
    ) {
        answered.insert(actionId)
        choices[actionId] = answer
        emit(
            .approvalAnswer(ApprovalAnswerData(actionId: actionId, answer: answer, rule: rule)),
            in: threadId
        )
    }

    /// Saves a rule: from the proposal card's editor, or from the Rules screen. The runtime
    /// answers with a fresh `rule_list`, which is what keeps two devices in step.
    public func saveRule(_ rule: ApprovalRule, proposalId: String? = nil) {
        if let proposalId { handledProposals.insert(proposalId) }
        emit(control(.ruleUpdate(RuleUpdateData(rule: rule))))
    }

    /// Revokes a rule outright.
    public func deleteRule(_ ruleId: String) {
        emit(control(.ruleDelete(RuleDeleteData(ruleId: ruleId))))
    }

    /// Asks for the stored rules. The Rules screens send this when they appear.
    public func requestRules() {
        emit(control(.ruleList(RuleListData())))
    }

    /// Reads or changes the Mac runtime's global approval bypass.
    public func requestApprovalSettings() {
        emit(control(.approvalSettings(ApprovalSettingsData())))
    }

    public func setYoloMode(_ enabled: Bool) {
        yoloMode = enabled
        emit(control(.approvalSettings(ApprovalSettingsData(yolo: enabled))))
    }

    /// "Not now" on a proposal: nothing is stored either way, so this is view state only.
    public func dismissProposal(_ proposalId: String) {
        handledProposals.insert(proposalId)
    }

    /// Answers a question the agent asked, in the thread it asked it in. The agent's `ask_user`
    /// call is suspended on this: until it arrives, or expires, the turn is parked.
    public func answerQuestion(_ questionId: String, in threadId: String, _ answer: String) {
        answeredQuestions.insert(questionId)
        questionChoices[questionId] = answer
        emit(.questionAnswer(QuestionAnswerData(questionId: questionId, answer: answer)), in: threadId)
    }

    private func emit(_ payload: YorozuEvent.Payload, in threadId: String) {
        emit(event(payload, in: threadId))
    }

    /// A frame that is about the runtime rather than in a thread: `threadId` is not read for it.
    private func control(_ payload: YorozuEvent.Payload) -> YorozuEvent {
        event(payload, in: "")
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
        let previous = emitter
        emitter = Task { [transport] in
            await previous?.value
            try? await transport.send(event)
        }
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
                // Pull is truth. Nothing sent while this socket was down was kept for us —
                // thread, device and rule lists live in no thread's log — so every join asks
                // for all of it again rather than trusting whatever was last pushed.
                emit(.threadList(ThreadListData(threads: [])), in: "")
                requestSync()
                requestDevices()
                requestRules()
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
                synced = data.threads.map { remote in
                    guard let pending = pendingReads[remote.id] else { return remote }
                    if (remote.lastReadAt ?? 0) >= pending {
                        pendingReads[remote.id] = nil
                        return remote
                    }
                    var merged = remote
                    merged.lastReadAt = pending
                    return merged
                }
                listed = true
                cache?.save(threads: synced)
                onThreads?()
            case .syncDelta(let data):
                for event in data.events { upsert(event) }
                if let workingThreadIds = data.workingThreadIds {
                    generating = Set(workingThreadIds)
                }
                if data.more == true { requestSync() }
                else {
                    syncRevision += 1
                    // Counted only once the sync is whole: a background drain is waiting for
                    // exactly this to know it has caught up and may hang up, and a page with
                    // `more` behind it would let it hang up mid-catch-up. See ``drain(timeout:)``.
                    deltas += 1
                }
            // What the model picker offers, sent with every thread list. Not a thread's event.
            case .modelList(let data):
                models = data.models
            // About the devices rather than in a thread, like the thread list above it.
            case .deviceList(let data):
                devices = data.devices
                onDevices?()
            // The stored rules, in answer to `rule_list` and after any change to them. Also
            // not a thread's event: rules are global, which is the whole point of them.
            case .ruleList(let data):
                rules = data.rules
                onRules?()
            case .approvalSettings(let data):
                if let yolo = data.yolo { yoloMode = yolo }
            default:
                applyEvent(event)
            }
        case .failed(let reason):
            flushStreamEvents()
            failure = reason
        }
    }

    private func applyEvent(_ event: YorozuEvent) {
        let key = "\(event.threadId)\u{0}\(event.id)"
        if case .message(let data) = event.payload, data.role == .agent, data.done != true {
            pendingStreamEvents[key] = event
            guard streamFrame == nil else { return }
            streamFrame = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                self?.flushStreamEvents()
            }
            return
        }

        // A terminal event supersedes any partial text still waiting for its frame. Cancelling
        // it prevents stale partial text from overwriting the finished reply 50 ms later.
        pendingStreamEvents.removeValue(forKey: key)
        // Preserve wire order for a tool/card/event arriving after streamed prose. A terminal
        // event for this same message removed its stale partial above, so only other messages
        // are flushed before it.
        flushStreamEvents()
        upsert(event)
    }

    private func flushStreamEvents() {
        streamFrame?.cancel()
        streamFrame = nil
        let events = pendingStreamEvents.values.sorted {
            ($0.ts, $0.id) < ($1.ts, $1.id)
        }
        pendingStreamEvents.removeAll(keepingCapacity: true)
        for event in events { upsert(event) }
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

    /// Test-only: a turn that used tools — one that worked, one that printed a diff, and one
    /// that failed — so the grouped tool rows and their expanded output can be screenshotted
    /// without a provider that actually calls anything.
    public func previewTools(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(id: "showcase-tools-ask", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(role: .user, text: "Tidy up the invoice script and run it"))))
        let calls: [(String, String, [String: JSONValue], Bool, String)] = [
            (
                "t1", "read_file", ["path": .string("scripts/invoices.py")], true,
                "import csv\nfrom pathlib import Path\n\nROWS = Path(\"invoices.csv\")\n"
            ),
            (
                "t2", "edit_file", ["path": .string("scripts/invoices.py")], true,
                "--- a/scripts/invoices.py\n+++ b/scripts/invoices.py\n@@ -1,4 +1,5 @@\n import csv\n+import sys\n from pathlib import Path\n-ROWS = Path(\"invoices.csv\")\n+ROWS = Path(sys.argv[1])\n"
            ),
            (
                "t3", "run_command", ["command": .string("python scripts/invoices.py")], false,
                "Traceback (most recent call last):\n  File \"scripts/invoices.py\", line 5\nIndexError: list index out of range\n"
            ),
        ]
        for (offset, call) in calls.enumerated() {
            let (id, name, args, ok, output) = call
            upsert(YorozuEvent(id: "showcase-call-\(id)", threadId: threadId, ts: now + offset * 2 + 1,
                agentId: "main", payload: .toolCall(ToolCallData(callId: id, name: name, args: args))))
            upsert(YorozuEvent(id: "showcase-result-\(id)", threadId: threadId, ts: now + offset * 2 + 2,
                agentId: "main", payload: .toolResult(ToolResultData(callId: id, ok: ok, output: output))))
        }
        upsert(YorozuEvent(id: "showcase-tools-reply", threadId: threadId, ts: now + 20, agentId: "main",
            payload: .message(MessageData(
                role: .agent,
                text: "The script now takes the CSV as an argument, but it needs one — running it bare is what raised the `IndexError`. Pass the file and it goes through.",
                done: true
            ))))
    }

    /// Same live activity fixture on Mac and iOS, without invoking a provider.
    public func previewActivity(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let payloads: [YorozuEvent.Payload] = [
            .message(MessageData(role: .user, text: "Inspect the project and check the build")),
            .thought(ThoughtData(text: "Checking project files…")),
            .toolCall(ToolCallData(callId: "read", name: "read_file", args: ["path": .string("Package.swift")])),
            .toolResult(ToolResultData(callId: "read", ok: true, output: "Shared Mac and iOS package found.")),
            .toolCall(ToolCallData(callId: "build", name: "build", args: [:])),
        ]
        for (index, payload) in payloads.enumerated() {
            upsert(YorozuEvent(id: "activity-\(index)", threadId: threadId, ts: now + index, agentId: "main", payload: payload))
        }
        upsert(YorozuEvent(id: "activity-delegation", threadId: threadId, ts: now + 10, agentId: "Reviewer", parentAgentId: "main", payload: .thought(ThoughtData(text: "Reviewing changes…"))))
        generating.insert(threadId)
    }

    /// Test-only: several pictures in one message for grid and viewer screenshots.
    public func previewImages(in threadId: String, images: [MessageAttachment]) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(
            id: "showcase-images", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(
                role: .user,
                text: "Here's the kitchen from a few angles — which tap would you get?",
                attachments: images
            ))
        ))
        upsert(YorozuEvent(
            id: "showcase-images-reply", threadId: threadId, ts: now + 1, agentId: "main",
            payload: .message(MessageData(
                role: .agent,
                text: "The pull-out tap beside the window fits best.",
                done: true
            ))
        ))
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

    /// Test-only: a card with the whole structured scope on it — merchant, account, quantity,
    /// what it says and what happens afterwards — plus the rule its "Always allow" would open.
    /// The picture story 17 is about, and what ``previewRuleEditor`` opens the editor over.
    public func previewStructuredApproval(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(id: "showcase-user", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(role: .user, text: "Reorder the Ethiopia Guji from Kurasu"))))
        upsert(YorozuEvent(id: "showcase-card", threadId: threadId, ts: now + 1, agentId: "main",
            payload: .approvalCard(Self.previewPurchaseCard)))
        generating.insert(threadId)
    }

    /// The purchase both the card and the editor screenshots are about.
    public static let previewPurchaseCard = ApprovalCardData(
        actionId: "showcase-purchase",
        actionClass: "purchase",
        target: "Ethiopia Guji, whole bean · 1kg",
        amount: 32,
        scope: ApprovalScope(
            operation: "purchase",
            account: "Visa ••4242",
            merchant: "Kurasu",
            category: "groceries",
            quantity: 1,
            contentSummary: "Ethiopia Guji washed, 1kg whole bean, ground to order — delivered to the home address.",
            consequence: "Charges the Visa now and ships within two days. Refundable for 14 days."
        ),
        suggestedRule: ApprovalRule(
            id: "showcase-rule",
            actionClass: "purchase",
            decision: .always,
            scope: [
                "merchant": ApprovalRuleField(mode: .exact, value: "Kurasu"),
                "account": ApprovalRuleField(mode: .exact, value: "Visa ••4242"),
                "category": ApprovalRuleField(mode: .exact, value: "groceries"),
                "operation": ApprovalRuleField(mode: .exact, value: "purchase"),
            ],
            maxAmount: 48
        )
    )

    /// Test-only: one decision over an exact list of twelve emails, each with its recipient and
    /// its subject. The picture story 25 is about.
    public func previewBatchApproval(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(id: "showcase-user", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(role: .user, text: "Send the April invoice reminder to everyone still open"))))
        let recipients = [
            "bob@kitanoya.example", "carol@marumi.example", "dave@sanwa.example",
            "erin@tsuruya.example", "frank@yamato.example", "grace@hoshino.example",
            "heidi@kawano.example", "ivan@morita.example", "judy@aoki.example",
            "ken@shibata.example", "lena@ueda.example", "mia@nakano.example",
        ]
        upsert(YorozuEvent(id: "showcase-card", threadId: threadId, ts: now + 1, agentId: "main",
            payload: .approvalCard(ApprovalCardData(
                actionId: "showcase-batch",
                actionClass: "send-message",
                target: "12 recipients",
                scope: ApprovalScope(
                    operation: "send",
                    contentSummary: "April invoice — the terms are thirty days and it falls due at the end of the month.",
                    consequence: "Sends twelve separate emails from the user's own Mail account. They cannot be recalled."
                ),
                // No suggested rule: a batch decision is about exactly these twelve, and no
                // standing rule can mean that. See `cardFor` in packages/runtime/src/approval.ts.
                items: recipients.map { BatchItem(label: $0, detail: "April invoice reminder") }
            ))))
        generating.insert(threadId)
    }

    /// Test-only: the rule Yorozu offers after three matching approvals. The picture story 22
    /// is about — a card with Review and Not now on it, and nothing saved either way.
    public func previewRuleProposal(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(id: "showcase-user", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(role: .user, text: "Reorder the Ethiopia Guji from Kurasu"))))
        upsert(YorozuEvent(id: "showcase-reply", threadId: threadId, ts: now + 1, agentId: "main",
            payload: .message(MessageData(role: .agent, text: "Ordered — ¥32 on the Visa, shipping in two days.", done: true))))
        upsert(YorozuEvent(id: "showcase-proposal", threadId: threadId, ts: now + 2, agentId: "main",
            payload: .ruleProposal(RuleProposalData(
                proposalId: "showcase-proposal",
                rule: Self.previewPurchaseCard.suggestedRule!,
                approvals: 3
            ))))
    }

    /// Test-only: a waiting choice, so both platforms can render the real question card.
    public func previewQuestion(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(id: "showcase-user", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(role: .user, text: "Book somewhere quiet for dinner"))))
        upsert(YorozuEvent(id: "showcase-question", threadId: threadId, ts: now + 1, agentId: "main",
            payload: .questionCard(QuestionCardData(
                questionId: "showcase-question",
                question: "Which neighbourhood should I search?",
                options: ["Ginza", "Ebisu", "Kagurazaka"],
                allowOther: true
            ))))
        generating.insert(threadId)
    }

    /// Test-only: a live multi-step job, so both platforms can render the real progress card.
    public func previewProgress(in threadId: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        upsert(YorozuEvent(id: "showcase-user", threadId: threadId, ts: now, agentId: device,
            payload: .message(MessageData(role: .user, text: "Prepare the September expense report"))))
        upsert(YorozuEvent(id: "showcase-progress", threadId: threadId, ts: now + 1, agentId: "main",
            payload: .progressCard(ProgressCardData(
                cardId: "showcase-progress",
                title: "Preparing expense report",
                steps: [
                    ProgressStep(label: "Collect receipts", state: .done),
                    ProgressStep(label: "Match transactions", state: .running),
                    ProgressStep(label: "Export report", state: .pending),
                ],
                percent: 55
            ))))
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
            // A reconnect sync can race a live relay frame. Put the older synced event back
            // where its runtime timestamp belongs instead of preserving network arrival order.
            // Equal timestamps keep arrival order, which also keeps call before result.
            let index = thread.lastIndex(where: { $0.ts <= event.ts }).map { $0 + 1 } ?? 0
            thread.insert(event, at: index)
        }
        events[event.threadId] = thread
        // The agent's last message ends the turn, whether it streamed or arrived whole.
        if case .message(let data) = event.payload, data.role == .agent, data.done == true,
            event.parentAgentId == nil
        {
            generating.remove(event.threadId)
        }
        // Not per streaming delta: sealing and writing the whole thread for every frame of a
        // long reply is a stutter, and the finished message lands here with `done` anyway.
        if case .message(let data) = event.payload, data.role == .agent, data.done != true {
        } else {
            cache?.save(events: thread, threadId: event.threadId)
        }
        // Nothing is raised here: the dot is the runtime's answer, not this device's guess.
        // What a reply landing in the thread somebody is actually reading does is report it
        // read, which is what keeps the dot from appearing on the other device a moment later.
        if case .message(let data) = event.payload, data.role == .agent, isReading(event.threadId) {
            reportReadSoon()
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
