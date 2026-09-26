import Foundation
#if os(iOS)
import UIKit
#endif

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
    /// Every thread, unsent drafts included, newest first once a list has ordered them.
    public var threads: [ThreadSummary] { draftThreads + synced }
    /// The threads the runtime has told us about.
    private var synced: [ThreadSummary] = []
    /// Threads started on this device that the runtime has not heard of yet.
    private var draftThreads: [ThreadSummary] = []
    /// The newest unsent draft.
    public var draft: ThreadSummary? { draftThreads.first }

    public func isDraft(_ threadId: String) -> Bool {
        draftThreads.contains { $0.id == threadId }
    }
    /// Whether a `thread_list` has arrived yet, so an app can wait before deciding what to open.
    public private(set) var listed = false
    /// Advances after a complete sync response. Notification navigation uses this to tell
    /// "events have not arrived yet" from "refresh finished and there is no message anchor".
    public private(set) var syncRevision = 0
    /// Events per thread id, oldest first.
    public var events: [String: [YorozuEvent]] {
        _ = timelineRevision
        return timelines.mapValues(\.events)
    }
    private var timelineRevision = 0
    @ObservationIgnored private var timelines: [String: ThreadTimeline] = [:]

    func timeline(_ id: String) -> ThreadTimeline {
        if let timeline = timelines[id] { return timeline }
        let timeline = ThreadTimeline()
        timelines[id] = timeline
        timelineRevision = timelines.count
        return timeline
    }
    public private(set) var state: TransportState = .connecting { didSet { markInterruption() } }
    /// Starts pessimistic: the transport tells us the truth when it connects.
    public private(set) var ownerOnline = false { didSet { markInterruption() } }
    /// When the link to this host was lost, and nil while it is up. The anchor for
    /// ``ConnectionPresentation``'s grace, kept per host rather than per view so a chat opened
    /// an hour into an outage says so at once instead of waiting out a grace of its own. A
    /// hang-up for suspension is not an interruption: the anchor clears, and the next
    /// ``start()`` begins a fresh one.
    public private(set) var interruptedSince: ContinuousClock.Instant?
    /// This host's link as a status line words it: an interruption shorter than the grace
    /// never changes it. It starts as not yet connected, the truth before the first
    /// connection. A toast keeps a presentation of its own, since it should say nothing at
    /// all until there is something to say.
    public let link = ConnectionPresentation(.reconnecting)
    /// Unlike status lines, a new list starts without a connection toast. Keeping this per
    /// host lets a merged list respect each host's own grace and initial connection attempt.
    public let toastLink = ConnectionPresentation(.connected)
    public let connectionToast = ConnectionToastPresentation()

    private func markInterruption() {
        let actual = ConnectionState(state: state, ownerOnline: ownerOnline)
        if !started || actual == .connected {
            interruptedSince = nil
        } else if interruptedSince == nil {
            interruptedSince = .now
        }
        link.update(actual, active: started, since: interruptedSince)
        toastLink.update(actual, active: started, since: interruptedSince)
    }
    public private(set) var peerInfo: PeerInfoData?
    public private(set) var compatibility: PeerCompatibility = .legacy
    public private(set) var updateStatus = UpdateStatusData(phase: .none)
    public var onUpdateStatus: ((UpdateStatusData) -> Void)?
    public private(set) var failure: String?
    /// The last failure the transport reported, until the link pairs again. It is also
    /// ``failure``, which status lines read; the transcript leaves it to its connection toast,
    /// so every dropped socket does not push a banner in and out above the messages.
    public private(set) var linkFailure: String?
    /// Action IDs already answered from this device, so the card stops offering buttons.
    public private(set) var answered: Set<String> = []
    public private(set) var approvalOutcomes: [String: ApprovalStatusData.Status] = [:]
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
    /// When the bypass switches itself off, in epoch ms. Nil while it is off.
    public private(set) var yoloUntil: Int?
    /// What this device chose for each answered action, so the card can say so afterwards.
    public private(set) var choices: [String: ApprovalAnswerData.Answer] = [:]
    /// One composer draft per thread, so switching threads does not lose what was typed.
    public var drafts: [String: String] = [:] { didSet { saveComposerSoon() } }
    /// Files staged in each thread's composer but not yet sent, alongside its draft text.
    public var attachments: [String: [MessageAttachment]] = [:] { didSet { saveComposerSoon() } }
    /// Threads with a turn in flight, so the composer offers Stop rather than Send.
    ///
    /// Set when this device sends, cleared by the agent message flagged `done` or confirmed
    /// Stop status. The composer can send another message while Stop is pending.
    /// It is per-process and starts empty: a turn another device started is not ours to stop.
    public private(set) var generating: Set<String> = []
    /// Every device the runtime answers, newest list wins. Only the Mac's Settings draws these.
    public private(set) var devices: [DeviceInfo] = []
    /// Includes empty replies, so pairing can await a confirmed list before showing its code.
    public private(set) var deviceListRevision = 0
    /// Every model a thread can be put on, as the Mac has it configured. Arrives with the
    /// thread list; empty until then, which is a picker that offers only Default.
    public private(set) var models: [ModelOption] = []
    public private(set) var agentModels: [String: [ModelOption]] = [:]

    public func models(for thread: ThreadSummary) -> [ModelOption] {
        guard let agent = thread.agent, agent != .yorozu else { return models }
        return agentModels[agent.rawValue] ?? []
    }

    /// The efforts a thread may ask for: its model's, or the first model's while it is on Default.
    public func efforts(for thread: ThreadSummary) -> [ReasoningEffort] {
        efforts(for: thread, on: thread.model)
    }

    private func efforts(for thread: ThreadSummary, on model: String?) -> [ReasoningEffort] {
        let models = models(for: thread)
        return (models.first { $0.id == model } ?? models.first)?.efforts ?? []
    }
    /// Where a coding agent's thread can be started, recents first, as the Mac last listed
    /// them. Arrives with the thread list; empty until then.
    public private(set) var projects: [ProjectFolder] = []
    private var projectsRevision = 0
    private var projectsRefreshing = false
    private var projectsFailed = false

    public var projectListStatus: ProjectListStatus {
        guard canDeliver else { return .offline }
        if projectsRefreshing { return .loading }
        if projectsFailed { return .failed }
        return projectsRevision == 0 && projects.isEmpty ? .loading : .ready
    }

    /// Refreshes the existing host's allowed folders, preserving the last answer while waiting.
    /// A bounded wait gives the picker a retry action when a connected host fails to answer.
    public func refreshProjects(timeout: Duration = .seconds(10)) async {
        guard canDeliver, !projectsRefreshing else { return }
        projectsRefreshing = true
        projectsFailed = false
        let revision = projectsRevision
        defer {
            projectsRefreshing = false
            // Dismissing the sheet cancels its request task; do not leave a loading state
            // behind when there has never been a response. Opening it again requests afresh.
            if projectsRevision == 0 && projects.isEmpty { projectsFailed = true }
        }
        emit(.projectList(ProjectListData(projects: [])), in: "")
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while projectsRevision == revision, canDeliver, !Task.isCancelled,
            ContinuousClock.now < deadline
        {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
        if !Task.isCancelled, canDeliver, projectsRevision == revision { projectsFailed = true }
    }
    /// Messages typed with nowhere to send them, oldest first. Persisted, so a phone closed on
    /// the underground still has them when it comes back up. See ``OutboxItem``.
    public private(set) var outbox: [OutboxItem] = []
    /// The thread the user is looking at, set by whatever owns the navigation: the top of the
    /// phone's path, or the Mac's sidebar selection. Nil means none is open.
    public var openThread: String? {
        didSet {
            if openThread != oldValue {
                reportRead()
                saveComposerSoon()
                requestOpenHistory()
            }
        }
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
    private var cache: ThreadCache?
    @ObservationIgnored private var cacheWrite: Task<Void, Never>?
    @ObservationIgnored private var composerWrite: Task<Void, Never>?
    @ObservationIgnored private var preparedSend: [String: String] = [:]
    @ObservationIgnored private var readingPositions: [String: ThreadCache.ReadingPosition] = [:]
    @ObservationIgnored private var pendingSaveFailure: String?

    public func readingPosition(in threadID: String) -> ThreadCache.ReadingPosition? {
        readingPositions[threadID]
    }

    public func rememberReadingPosition(_ position: ThreadCache.ReadingPosition?, in threadID: String) {
        guard readingPositions[threadID] != position else { return }
        readingPositions[threadID] = position
        saveComposerSoon()
    }

    private func saveComposerSoon() {
        guard cache != nil else { return }
        composerWrite?.cancel()
        composerWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            do { try self.saveComposer() }
            catch { self.failure = "Could not save draft: \(error.localizedDescription)" }
        }
    }

    private func saveComposer() throws {
        try cache?.save(composer: .init(drafts: drafts, attachments: attachments, threads: draftThreads,
                                       knownThreads: synced, openThread: openThread,
                                       readingPositions: readingPositions.isEmpty ? nil : readingPositions,
                                       preparedSend: preparedSend.isEmpty ? nil : preparedSend))
    }
    /// Replay progress follows the runtime's log order, independently of live events and
    /// the timeline's timestamp order. Advancing from either can skip unseen sync pages.
    private var syncLastSeen: [String: String] = [:]
    private var lastSyncFocus: String?
    private var historyCursors: [String: String] = [:]
    private var historyLoaded: Set<String> = []
    private var historyInFlight: Set<String> = []

    private func persistEvents(in ids: Set<String>) {
        guard cache != nil else { return }
        persist(events: Dictionary(uniqueKeysWithValues: ids.map { ($0, timeline($0).events) }))
    }

    private func persist(threads: [ThreadSummary]? = nil, events: [String: [YorozuEvent]] = [:]) {
        guard let cache else { return }
        let previous = cacheWrite
        let lastSeen = syncLastSeen
        let historyCursors = historyCursors
        let historyLoaded = historyLoaded
        // Value snapshots are sealed and written on a worker, in order. The outbox keeps its
        // separate synchronous durability boundary: unsent user input must never be lost.
        cacheWrite = Task.detached(priority: .utility) {
            await previous?.value
            if let threads { cache.save(threads: threads) }
            for (id, events) in events {
                cache.save(events: events, threadId: id, lastSeen: lastSeen[id],
                           historyCursor: historyCursors[id], historyLoaded: historyLoaded.contains(id))
            }
        }
    }

    /// Await before suspension. Include the composer even if its debounced write has not fired.
    public func flushCache() async {
        await cacheWrite?.value
        composerWrite?.cancel()
        do { try saveComposer() }
        catch { failure = "Could not save draft: \(error.localizedDescription)" }
    }
    /// What this client tags the events it emits with.
    private let device: String
    private var started = false
    private var stopped = false
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// How many `sync_delta`s have been applied, which is what a background drain waits on.
    private var deltas = 0
    /// One flush at a time: the queue is sent in order, and two loops draining it would not be.
    private var flushing = false
    private var flushAgain = false
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
        toastLink.onStateChange = { [weak self] state in self?.connectionToast.declared(state) }
        guard let cache else { return }
        peerInfo = cache.peerInfo()
        synced = cache.threads()
        syncLastSeen = cache.lastSeen()
        let storedPending = cache.outbox()
        var pending = storedPending
        let migrationTime = Date()
        for index in pending.indices {
            guard case .message(let data) = pending[index].event.payload, data.role == .user,
                  data.admissionDeadline == nil, pending[index].replacementId == nil,
                  pending[index].admissionStatus == nil, pending[index].legacyHoldUntil == nil else { continue }
            if pending[index].attemptedAt == nil { pending[index].admissionStatus = .expired }
            else { pending[index].legacyHoldUntil = migrationTime.addingTimeInterval(25 * 60 * 60) }
        }
        if pending != storedPending {
            do { try cache.savePending(pending) }
            catch { failure = "Could not save pending-message migration: \(error.localizedDescription)" }
        }
        outbox = Outbox.pruned(pending)
        if let composer = cache.composer() {
            drafts = composer.drafts
            attachments = composer.attachments
            draftThreads = composer.threads
            openThread = composer.openThread
            readingPositions = composer.readingPositions ?? [:]
            for thread in composer.knownThreads ?? [] where !synced.contains(where: { $0.id == thread.id }) {
                synced.append(thread)
            }
            // A crash can land between the composer marker, outbox write, and composer clear.
            // The marker names the exact message: committed sends leave the composer; failed
            // prepares keep it. Never infer this from matching text, which a user may repeat.
            if let prepared = composer.preparedSend, !prepared.isEmpty {
                for (threadId, eventId) in prepared where outbox.contains(where: { $0.id == eventId }) {
                    drafts[threadId] = ""
                    attachments[threadId] = nil
                    if let index = draftThreads.firstIndex(where: { $0.id == threadId }) {
                        let draft = draftThreads.remove(at: index)
                        if !synced.contains(where: { $0.id == threadId }) { synced.insert(draft, at: 0) }
                    }
                }
                do { try saveComposer() }
                catch { failure = "Could not save draft: \(error.localizedDescription)" }
            }
        }
        for thread in synced {
            let history = cache.historyState(threadId: thread.id)
            historyCursors[thread.id] = history.cursor
            if history.loaded { historyLoaded.insert(thread.id) }
            // Older clients replaced streamed replies in place, leaving their final
            // timestamp ahead of the tool history below them in the saved array.
            let events = cache.events(threadId: thread.id).sorted { $0.ts < $1.ts }
            timeline(thread.id).events = events
            for event in events { applyAnswerState(event) }
        }
        for item in outbox {
            if case .message = item.event.payload { upsert(item.event, persist: false) }
            if item.event.payload.kind != .approvalAnswer { applyAnswerState(item.event) }
        }
        armOutboxRetry()
    }

    /// Connects and applies updates until the transport ends. Calling it twice does nothing.
    public func start() {
        guard !started, !stopped else { return }
        started = true
        markInterruption()
        connectionTask = Task { [weak self] in
            guard let stream = await self?.transport.connect() else { return }
            for await update in stream {
                guard !Task.isCancelled else { break }
                self?.apply(update)
            }
        }
    }

    public func close() {
        retryTask?.cancel()
        retryTask = nil
        Task { [transport] in await transport.close() }
    }

    /// Permanently retires this connection before its owner removes or repairs the host.
    /// Detached cache writes keep their snapshots alive, so cancellation alone is not enough:
    /// wait for them before allowing the host's keys and files to be erased.
    public func shutdown() async {
        flushStreamEvents()
        do { try saveComposer() }
        catch { failure = "Could not save draft: \(error.localizedDescription)" }
        stopped = true
        foreground = false
        connectionTask?.cancel()
        readReport?.cancel()
        streamFrame?.cancel()
        composerWrite?.cancel()
        flushTask?.cancel()
        retryTask?.cancel()
        emitter?.cancel()
        cache = nil
        await transport.close()
        await connectionTask?.value
        await emitter?.value
        await flushTask?.value
        await cacheWrite?.value
        state = .closed
        ownerOnline = false
    }

    /// Hangs up ahead of a suspension. iOS freezes the app with whatever socket it holds, and
    /// from the relay that frozen socket is indistinguishable from a phone that is watching —
    /// which is exactly the phone it does not send a silent catch-up to. A closed socket is
    /// the truth; the next ``start()`` dials afresh.
    public func suspend() {
        close()
        // The stream is finished, so the next foreground has to start a new one rather than
        // reconnect a transport that has already hung up.
        started = false
        markInterruption()
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
        await flushCache()
        // A push can wake us in the background and finish after the user opens the app.
        // The foreground now owns this socket and still needs to receive live events.
        if !foreground { suspend() }
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
        defer { if !foreground { suspend() } }
        guard state == .paired, let (threadId, card) = approvalCard(eventRef: eventRef) else { return false }
        // Tagged as a button press: the runtime honours one only for a card it judged answerable
        // from the lock screen, whatever buttons the push happened to draw.
        self.answer(card.actionId, in: threadId, answer, source: .notification)
        guard approvalPending(card.actionId) || answered.contains(card.actionId) else { return false }
        // The durable answer has its own priority lane; wait for this drain before suspending.
        await flushTask?.value
        await flushCache()
        return true
    }

    /// The approval card whose event id the push referenced, wherever it is.
    private func approvalCard(eventRef: String) -> (String, ApprovalCardData)? {
        var match: (String, ApprovalCardData)?
        for (threadId, list) in events {
            for event in list where YorozuCrypto.threadRef(event.id) == eventRef {
                if case .approvalCard(let card) = event.payload {
                    guard match == nil else { return nil }
                    match = (threadId, card)
                }
            }
        }
        return match
    }

    /// Sends what the composer holds. Clear it only after the outbox owns the message.
    public func send(in thread: ThreadSummary) {
        let text = (drafts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = attachments[thread.id] ?? []
        // Files on their own are a message: only an empty composer is nothing to send.
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard queueMessage(text, in: thread.id, attachments: attachments, fromComposer: true) else { return }
        drafts[thread.id] = ""
        self.attachments[thread.id] = nil
        preparedSend[thread.id] = nil
        do { try saveComposer() }
        catch { failure = "Could not save draft: \(error.localizedDescription)" }
        flush()
    }

    public func send(_ text: String, in threadId: String, attachment: MessageAttachment? = nil) {
        send(text, in: threadId, attachments: attachment.map { [$0] } ?? [])
    }

    public func send(_ text: String, in threadId: String, attachments: [MessageAttachment]) {
        if queueMessage(text, in: threadId, attachments: attachments) { flush() }
    }

    @discardableResult
    private func queueMessage(_ text: String, in threadId: String, attachments: [MessageAttachment],
                              fromComposer: Bool = false) -> Bool {
        guard !stopped else { return false }
        // Decided once for the whole send: a thread created here and the message that creates it
        // must not take different routes, or the runtime is told about a message in a thread it
        // has never heard of.
        let queue = !canDeliver
        var commands: [YorozuEvent] = []
        if let draft = draftThreads.first(where: { $0.id == threadId }) {
            // A draft becomes real with its first message. The id is ours, so the message below
            // lands in the thread this `thread_create` is about to mint on the other end.
            // A draft for a coding agent carries who answers it and where; a Yorozu draft says
            // nothing, as every draft did before there was anyone else to ask.
            commands.append(event(.threadCreate(ThreadCreateData(title: nil, agent: draft.agent, cwd: draft.cwd)), in: threadId))
            // A model chosen in a chat that had not been sent in yet is held on the draft,
            // because there was no thread to set it on. This is that moment, and it goes
            // before the message so the first turn already runs on it.
            if let model = draft.model {
                commands.append(event(.threadSetModel(ThreadSetModelData(model: model)), in: threadId))
            }
            if let effort = draft.effort {
                commands.append(event(.threadSetEffort(ThreadSetEffortData(effort: effort)), in: threadId))
            }
        }
        let createdAt = Int(Date().timeIntervalSince1970 * 1000)
        let event = YorozuEvent(
            id: UUID().uuidString,
            threadId: threadId,
            ts: createdAt,
            agentId: device,
            payload: .message(MessageData(role: .user, text: text, attachments: attachments,
                admissionDeadline: createdAt + 30 * 60_000))
        )
        // Persist creation and its first message in one encrypted write. A failed write leaves
        // the composer and draft thread intact, with no phantom bubble or unsaved outbox item.
        let pending = Outbox.pruned(outbox + (commands + [event]).map { OutboxItem(event: $0) })
        if fromComposer {
            preparedSend[threadId] = event.id
            do { try saveComposer() }
            catch {
                preparedSend[threadId] = nil
                failure = "Could not save draft: \(error.localizedDescription)"
                return false
            }
        }
        do { try cache?.savePending(pending) }
        catch {
            let cause = error.localizedDescription
            if fromComposer { preparedSend[threadId] = nil }
            do { try saveComposer() }
            catch {
                failure = "Could not queue or save draft: \(error.localizedDescription)"
                return false
            }
            pendingSaveFailure = "Could not save pending messages: \(cause)"
            failure = pendingSaveFailure
            return false
        }
        if failure == pendingSaveFailure { failure = nil }
        pendingSaveFailure = nil
        outbox = pending
        if let draft = draftThreads.first(where: { $0.id == threadId }) {
            draftThreads.removeAll { $0.id == threadId }
            synced.insert(draft, at: 0)
            if !fromComposer {
                do { try saveComposer() }
                catch { failure = "Could not save draft: \(error.localizedDescription)" }
            }
        }
        // A queued message has started no turn: the composer stays a composer until the message
        // is actually on its way.
        if !queue { generating.insert(threadId) }
        upsert(event)
        armOutboxRetry()
        return true
    }

    /// Whether an event sent now would actually reach the runtime. Anything else — still
    /// dialling, joined at the relay but not paired, or paired with the Mac asleep — is what
    /// the outbox is for.
    public var canDeliver: Bool {
        if case .updateRequired = compatibility { return false }
        return !stopped && state == .paired && ownerOnline && updateStatus.phase != .installing
    }

    @discardableResult
    public func updateControl(_ action: UpdateControlData.Action, updateId: String? = nil, version: String? = nil) -> String {
        let request = event(.updateControl(UpdateControlData(action: action, updateId: updateId, version: version)), in: "")
        emit(request)
        return request.id
    }

    public func saveForRestart() throws {
        guard let cache else { throw CocoaError(.fileWriteUnknown) }
        try cache.savePending(outbox)
        try saveComposer()
    }

    /// A socket send is not host acceptance. Keep its pending caption until the host receipts it.
    public func outboxStatus(of eventId: String) -> OutboxStatus? {
        guard let item = outbox.first(where: { $0.id == eventId }) else { return nil }
        if outbox.contains(where: { $0.event.payload == .interrupt(InterruptData(targetEventId: eventId)) }) {
            return .withdrawalPending
        }
        return item.status
    }

    public func outboxRejectionReason(of eventId: String) -> String? {
        outbox.first(where: { $0.id == eventId })?.rejectionReason
    }

    /// Resumes a paused message after transport errors or age, keeping its operation ID.
    public func retry(_ eventId: String) {
        guard let index = outbox.firstIndex(where: { $0.id == eventId }) else { return }
        guard outbox[index].legacyHoldUntil == nil else { return }
        guard outbox[index].admissionDeadline == nil || !outbox[index].isExpired(at: Date()) else { return }
        guard outbox[index].admissionStatus != .rejected,
              outbox[index].admissionStatus != .withdrawn,
              outbox[index].replacementId == nil else { return }
        outbox[index].tries = 0
        outbox[index].nextAttemptAt = nil
        outbox[index].deliveryAttempts = nil
        outbox[index].reconfirmedAt = Date()
        saveOutbox()
        flush()
    }

    /// Explicit fresh intent after the host confirmed expiry (or this device never transmitted it).
    public func stillSend(_ eventId: String) {
        guard let index = outbox.firstIndex(where: { $0.id == eventId }),
              outbox[index].status == .expired,
              case .message(let original) = outbox[index].event.payload else { return }
        let old = outbox[index].event
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let renewed = YorozuEvent(id: UUID().uuidString, threadId: old.threadId, ts: ts,
            agentId: device, payload: .message(MessageData(role: .user, text: original.text,
                attachments: original.attachments, admissionDeadline: ts + 30 * 60_000)))
        var pending = outbox
        // A draft's creation and settings must reach the host before its renewed first message.
        // Their original IDs are safe to retry; the host deduplicates accepted operations.
        for predecessor in pending.indices where predecessor < index &&
            pending[predecessor].event.threadId == old.threadId &&
            pending[predecessor].isExpired(at: Date()) {
            switch pending[predecessor].event.payload {
            case .threadCreate, .threadSetModel, .threadSetEffort:
                pending[predecessor].tries = 0
                pending[predecessor].nextAttemptAt = nil
                pending[predecessor].deliveryAttempts = nil
                pending[predecessor].reconfirmedAt = Date()
            default: break
            }
        }
        pending[index].replacementId = renewed.id
        pending.append(OutboxItem(event: renewed))
        do { try cache?.savePending(pending) }
        catch {
            failure = "Could not save pending messages: \(error.localizedDescription)"
            return
        }
        outbox = pending
        upsert(renewed)
        armOutboxRetry()
        flush()
    }

    /// Asks the Mac for the whole of a truncated tool result. The answer is the same
    /// `tool_result` event, whole, under the id already in the thread, so it lands in place.
    @ObservationIgnored private var resultChunks: [String: (offset: Int, output: String)] = [:]

    private func resumeResultRequests() {
        for (key, partial) in resultChunks {
            let ids = key.split(separator: "\0", maxSplits: 1).map(String.init)
            guard ids.count == 2 else { continue }
            emit(.toolResultRequest(ToolResultRequestData(callId: ids[1], offset: partial.offset)), in: ids[0])
        }
    }

    public func requestToolResult(_ callId: String, in threadId: String) {
        resultChunks[threadId + "\0" + callId] = (0, "")
        emit(.toolResultRequest(ToolResultRequestData(callId: callId)), in: threadId)
    }

    /// Every message goes through the outbox, link or no link: it leaves only on the runtime's
    /// receipt, so a send onto a socket that was quietly dead is sent again rather than lost.
    /// `queue` says whether there was a link to try now.
    private func deliver(_ event: YorozuEvent, queue: Bool) {
        guard !stopped else { return }
        outbox = Outbox.pruned(outbox + [OutboxItem(event: event)])
        guard saveOutbox() else { return }
        if !queue { flush() }
    }

    /// Only the first unreceipted operation in a thread may be sent. A socket send remains
    /// uncertain until its host receipt; errors and missing receipts retry with the same ID.
    public func flush() {
        if flushing { flushAgain = true; return }
        guard canDeliver, !outbox.isEmpty, saveOutbox() else { return }
        queryExpiredAdmissions()
        retryTask?.cancel()
        retryTask = nil
        flushing = true
        flushTask = Task { [weak self] in
            var sent: Set<String> = []
            var blockedThreads: Set<String> = []
            while let self, !Task.isCancelled, self.canDeliver {
                let now = Date()
                guard let item = self.pendingHeads(at: now, blocking: blockedThreads).first(where: {
                    !sent.contains($0.id) && ($0.nextAttemptAt ?? .distantPast) <= now
                }), let index = self.outbox.firstIndex(where: { $0.id == item.id }) else { break }
                self.outbox[index].attemptedAt = self.outbox[index].attemptedAt ?? now
                let attempts = (item.deliveryAttempts ?? 0) + 1
                self.outbox[index].deliveryAttempts = attempts
                self.outbox[index].nextAttemptAt = now.addingTimeInterval(Outbox.retryDelay(after: attempts))
                guard self.saveOutbox() else { break }
                do {
                    try await self.transport.send(item.event)
                    sent.insert(item.id)
                    if let index = self.outbox.firstIndex(where: { $0.id == item.id }), self.outbox[index].tries > 0 {
                        self.outbox[index].tries = 0
                        self.saveOutbox()
                    }
                } catch {
                    self.bumpTries(of: item.id)
                    blockedThreads.insert(item.event.threadId)
                    guard self.saveOutbox() else { break }
                }
            }
            guard let self else { return }
            self.flushing = false
            self.saveOutbox()
            if self.flushAgain {
                self.flushAgain = false
                self.flush()
            } else {
                self.armOutboxRetry()
            }
        }
    }

    /// The runtime has this one. Only now is it out of the queue.
    private func receipted(_ eventId: String) {
        guard outbox.contains(where: { $0.id == eventId }) else { return }
        // Stop's receipt confirms durable intent, not that execution ceased.
        if outbox.contains(where: { $0.id == eventId &&
            ($0.event.payload.kind == .interrupt || $0.event.payload.kind == .approvalAnswer) }) { return }
        outbox.removeAll { $0.id == eventId }
        saveOutbox()
        flush()
    }

    private func reconcile(_ status: AdmissionStatusData) {
        guard let index = outbox.firstIndex(where: { $0.id == status.eventId }),
              case .message = outbox[index].event.payload else { return }
        if let requestId = status.requestId, requestId != outbox[index].lastStatusQueryId { return }
        if status.requestId == nil && (status.status == .unknown || status.status == .indeterminate) { return }
        switch status.status {
        case .accepted, .queued, .running, .completed:
            receipted(status.eventId)
        case .rejected, .expired, .unknown, .indeterminate, .withdrawn:
            outbox[index].admissionStatus = status.status
            outbox[index].rejectionReason = status.reason
            saveOutbox()
            flush()
        }
    }

    private func queryExpiredAdmissions() {
        let now = Date()
        var pending = outbox
        var queries: [YorozuEvent] = []
        for index in pending.indices {
            let item = pending[index]
            let due = item.legacyHoldUntil.map { hold in
                item.lastStatusQueryAt == nil || now >= hold && item.lastStatusQueryAt! < hold ||
                    now >= hold && now.timeIntervalSince(item.lastStatusQueryAt!) >= 15
            } ?? (item.admissionDeadline != nil && item.isExpired(at: now) &&
                now.timeIntervalSince(item.lastStatusQueryAt ?? .distantPast) >= 15)
            guard item.attemptedAt != nil, item.status(at: now) == .checking, due else { continue }
            let query = event(.admissionQuery(AdmissionQueryData(eventId: item.id)), in: item.event.threadId)
            pending[index].lastStatusQueryAt = now
            pending[index].lastStatusQueryId = query.id
            if item.legacyHoldUntil.map({ now >= $0 }) == true { pending[index].admissionStatus = nil }
            queries.append(query)
        }
        guard !queries.isEmpty else { return }
        do { try cache?.savePending(pending) }
        catch {
            failure = "Could not save pending messages: \(error.localizedDescription)"
            return
        }
        outbox = pending
        for query in queries { emit(query) }
    }

    private func bumpTries(of id: String) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox[index].tries += 1
    }

    private func pendingHeads(at now: Date, blocking blockedThreads: Set<String> = []) -> [OutboxItem] {
        var threads = blockedThreads
        let prioritized = outbox.filter { $0.event.payload.kind == .interrupt } +
            outbox.filter { $0.event.payload.kind == .approvalAnswer } +
            outbox.filter { $0.event.payload.kind != .interrupt && $0.event.payload.kind != .approvalAnswer }
        return prioritized.filter { item in
            guard !item.isExpired(at: now), item.admissionStatus != .rejected,
                  item.admissionStatus != .withdrawn, item.replacementId == nil else { return false }
            if item.event.payload.kind == .approvalAnswer { return !blockedThreads.contains(item.event.threadId) }
            guard threads.insert(item.event.threadId).inserted else { return false }
            return true
        }
    }

    private func armOutboxRetry() {
        let now = Date()
        let sends = canDeliver ? pendingHeads(at: now).compactMap(\.nextAttemptAt) : []
        let expiries = outbox.compactMap { item -> Date? in
            if let hold = item.legacyHoldUntil, item.status(at: now) == .checking, canDeliver {
                return item.lastStatusQueryAt == nil ? now :
                    item.lastStatusQueryAt! < hold ? hold : max(now, item.lastStatusQueryAt!.addingTimeInterval(15))
            }
            guard let deadline = item.admissionDeadline, item.replacementId == nil else { return nil }
            if deadline > now { return deadline }
            guard canDeliver, item.status(at: now) == .checking else { return nil }
            return max(deadline, (item.lastStatusQueryAt ?? .distantPast).addingTimeInterval(15))
        }
        guard let next = (sends + expiries).min() else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            // The clock crossed a deadline even if offline; wake observation for the caption.
            self.outbox = Outbox.pruned(self.outbox)
            self.flush()
            if !self.canDeliver { self.armOutboxRetry() }
        }
    }

    @discardableResult
    private func saveOutbox() -> Bool {
        guard !stopped else { return false }
        outbox = Outbox.pruned(outbox)
        do {
            try cache?.savePending(outbox)
            try saveComposer()
            return true
        } catch {
            failure = "Could not save pending messages: \(error.localizedDescription)"
            return false
        }
    }

    public func activeEventId(in threadId: String) -> String? {
        synced.first(where: { $0.id == threadId })?.activeEventId
    }

    public func stopPending(in threadId: String) -> Bool {
        outbox.contains { item in
            item.event.threadId == threadId && item.event.payload.kind == .interrupt
        }
    }

    public func canWithdraw(_ event: YorozuEvent) -> Bool {
        guard case .message(let data) = event.payload, data.role == .user else { return false }
        if let item = outbox.first(where: { $0.id == event.id }) {
            return item.admissionStatus != .withdrawn && item.admissionStatus != .rejected &&
                item.replacementId == nil && !stopPending(for: event.id)
        }
        let history = timeline(event.threadId).events
        guard history.contains(where: { $0.id == event.id }), !stopPending(for: event.id) else { return false }
        return !history.contains { known in
            if case .stopStatus(let status) = known.payload {
                return status.targetEventId == event.id && status.status != .requested && status.status != .unknown
            }
            if case .message(let reply) = known.payload, reply.role == .agent, reply.done == true {
                return known.id == data.completionId || known.id.hasSuffix(":\(event.id):final")
            }
            return false
        }
    }

    private func stopPending(for eventId: String) -> Bool {
        outbox.contains { $0.event.payload == .interrupt(InterruptData(targetEventId: eventId)) }
    }

    public func hasUnconfirmedStop(in threadId: String) -> Bool {
        let events = timelines[threadId]?.events ?? []
        return events.contains { event in
            guard case .stopStatus(let status) = event.payload, status.status == .unconfirmed else { return false }
            return !events.contains { known in
                guard case .message(let reply) = known.payload, reply.role == .agent, reply.done == true else { return false }
                return known.id.hasSuffix(":\(status.targetEventId):final")
            }
        }
    }

    private func queueStop(_ targetEventId: String, in threadId: String) {
        guard !outbox.contains(where: { $0.event.payload == .interrupt(InterruptData(targetEventId: targetEventId)) }) else { return }
        let pending = outbox + [OutboxItem(event: event(.interrupt(InterruptData(targetEventId: targetEventId)), in: threadId))]
        do { try cache?.savePending(pending) }
        catch {
            failure = "Could not save Stop request: \(error.localizedDescription)"
            return
        }
        outbox = pending
        flush()
    }

    /// Persist Stop against the run the host last identified; await cessation evidence.
    public func interrupt(in threadId: String) {
        guard let targetEventId = activeEventId(in: threadId), !stopPending(in: threadId) else { return }
        queueStop(targetEventId, in: threadId)
    }

    /// Cancel locally only when no socket attempt began. Otherwise ask the host to settle the race.
    public func withdraw(_ eventId: String) {
        if let accepted = timelines.values.flatMap(\.events).first(where: { $0.id == eventId }),
           !outbox.contains(where: { $0.id == eventId }) {
            guard canWithdraw(accepted) else { return }
            queueStop(eventId, in: accepted.threadId)
            return
        }
        guard let index = outbox.firstIndex(where: { $0.id == eventId }),
              case .message = outbox[index].event.payload,
              outbox[index].replacementId == nil,
              outbox[index].admissionStatus != .withdrawn else { return }
        if outbox[index].attemptedAt != nil {
            queueStop(eventId, in: outbox[index].event.threadId)
            return
        }
        var pending = outbox
        pending[index].admissionStatus = .withdrawn
        // An untouched draft's setup belongs to its first message, not an empty remote chat.
        let threadId = pending[index].event.threadId
        let anotherMessage = pending.contains { item in
            guard item.id != eventId, item.event.threadId == threadId, item.admissionStatus != .withdrawn else { return false }
            if case .message = item.event.payload { return true }
            return false
        }
        if !anotherMessage {
            for predecessor in pending.indices where predecessor < index &&
                pending[predecessor].event.threadId == threadId &&
                pending[predecessor].attemptedAt == nil {
                switch pending[predecessor].event.payload {
                case .threadCreate, .threadSetModel, .threadSetEffort:
                    pending[predecessor].admissionStatus = .withdrawn
                default: break
                }
            }
        }
        do { try cache?.savePending(pending) }
        catch {
            failure = "Could not save withdrawal: \(error.localizedDescription)"
            return
        }
        outbox = pending
    }

    private func reconcileStop(_ status: StopStatusData) {
        guard let index = outbox.firstIndex(where: { item in
            item.id == status.requestId && item.event.payload == .interrupt(InterruptData(targetEventId: status.targetEventId))
        }) else { return }
        guard status.status == .stopped || status.status == .completed || status.status == .withdrawn ||
            status.status == .unconfirmed else { return }
        let threadId = outbox[index].event.threadId
        outbox.remove(at: index)
        if status.status == .unconfirmed {
            generating.remove(threadId)
            saveOutbox()
            return
        }
        if status.status == .withdrawn, let original = outbox.firstIndex(where: { $0.id == status.targetEventId }) {
            outbox[original].admissionStatus = .withdrawn
        } else if status.status == .stopped || status.status == .completed {
            outbox.removeAll { $0.id == status.targetEventId }
        }
        if status.status != .completed { generating.remove(threadId) }
        saveOutbox()
        flush()
    }

    /// Forgets one event on this device only: it stays in the runtime's thread log, and a
    /// device that syncs from scratch will see it again. Tidying a transcript, not deleting.
    public func delete(_ eventId: String, in threadId: String) {
        var thread = timeline(threadId).events
        thread.removeAll { $0.id == eventId }
        timeline(threadId).events = thread
        persistEvents(in: [threadId])
    }

    /// A thread that exists only on this device until its first message: nothing is sent until
    /// then. Starting another keeps drafts with input and removes empty ones.
    @discardableResult
    public func newDraft(agent: ThreadAgent = .yorozu, cwd: String? = nil) -> ThreadSummary {
        for id in draftThreads.map(\.id) { discardDraft(id) }
        let thread = ThreadSummary(
            id: UUID().uuidString,
            title: "",
            archived: false,
            lastActivity: Date().timeIntervalSince1970 * 1000,
            agent: agent == .yorozu ? nil : agent,
            cwd: agent == .yorozu ? nil : cwd
        )
        draftThreads.insert(thread, at: 0)
        saveComposerSoon()
        return thread
    }

    /// Leaving a draft discards it only when its composer is empty.
    public func discardDraft(_ threadId: String) {
        guard (drafts[threadId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (attachments[threadId] ?? []).isEmpty
        else { return }
        removeDraft(threadId)
    }

    private func removeDraft(_ threadId: String) {
        guard isDraft(threadId) else { return }
        draftThreads.removeAll { $0.id == threadId }
        drafts[threadId] = nil
        attachments[threadId] = nil
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
        guard !isDraft(thread.id) else {
            if archived { removeDraft(thread.id) }
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
        guard !isDraft(thread.id) else { return }
        set(thread.id) { $0.pinned = pinned }
        emit(.threadPin(ThreadPinData(pinned: pinned)), in: thread.id)
    }

    /// Runs this thread on one model rather than the Mac's configured chain: `model` is a spec
    /// from ``models``, and nil puts it back on the default. A thread nothing has been sent in
    /// yet keeps the choice on the draft — there is no thread on the Mac to set it on until the
    /// first message, which carries it along (see ``send(_:in:attachment:)``).
    public func setModel(_ thread: ThreadSummary, _ model: String?) {
        // An effort the new model does not offer goes with the switch; one it does is kept.
        let effort = thread.effort.flatMap { efforts(for: thread, on: model).contains($0) ? $0 : nil }
        if let index = draftThreads.firstIndex(where: { $0.id == thread.id }) {
            draftThreads[index].model = model
            draftThreads[index].effort = effort
            return
        }
        set(thread.id) { $0.model = model; $0.effort = effort }
        emit(.threadSetModel(ThreadSetModelData(model: model)), in: thread.id)
    }

    public func recover(_ thread: ThreadSummary, action: ThreadRecoverData.Action) {
        guard let turnId = thread.interruptedTurnId else { return }
        emit(.threadRecover(ThreadRecoverData(turnId: turnId, action: action)), in: thread.id)
    }

    public func setBypass(_ thread: ThreadSummary, _ bypass: Bool) {
        guard thread.agent?.needsFolder == true else { return }
        setYoloMode(bypass)
    }

    /// Sets how much reasoning this thread requests, or returns it to the provider default.
    /// Drafts keep the choice locally until their first message creates them on the runtime.
    public func setEffort(_ thread: ThreadSummary, _ effort: ReasoningEffort?) {
        if let index = draftThreads.firstIndex(where: { $0.id == thread.id }) {
            draftThreads[index].effort = effort
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
        guard let openThread, !isDraft(openThread), isReading(openThread) else { return }
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
        rule: ApprovalRule? = nil,
        source: ApprovalAnswerData.Source? = nil
    ) {
        guard !answered.contains(actionId), !approvalPending(actionId),
              approvalOutcomes[actionId] != .noLongerNeeded,
              approvalOutcomes[actionId] != .expired else { return }
        let request = event(.approvalAnswer(ApprovalAnswerData(
            actionId: actionId, answer: answer, rule: rule, source: source)), in: threadId)
        let pending = Outbox.pruned(outbox + [OutboxItem(event: request)])
        do { try cache?.savePending(pending) }
        catch {
            failure = "Could not save approval answer: \(error.localizedDescription)"
            return
        }
        outbox = pending
        flush()
    }

    public func approvalPending(_ actionId: String) -> Bool {
        outbox.contains { item in
            if case .approvalAnswer(let answer) = item.event.payload { return answer.actionId == actionId }
            return false
        }
    }

    private func retireApproval(_ status: ApprovalStatusData) {
        if let index = outbox.firstIndex(where: { $0.id == status.requestId }),
           case .approvalAnswer(let answer) = outbox[index].event.payload,
           answer.actionId == status.actionId {
            if status.status == .applied { choices[status.actionId] = answer.answer }
            outbox.remove(at: index)
            saveOutbox()
            flush()
        }
    }

    private func reconcileApproval(_ status: ApprovalStatusData, event: YorozuEvent) {
        retireApproval(status)
        if status.status == .rejected { failure = "Approval answer could not be applied." }
        applyEvent(event)
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
        guard !stopped else { return }
        switch event.payload {
        case .threadRecover, .threadCreate, .threadRename, .threadPin, .threadSetModel,
             .threadSetEffort, .threadRead, .approvalAnswer, .questionAnswer:
            deliver(event, queue: !canDeliver)
            return
        default: break
        }
        let previous = emitter
        emitter = Task { [weak self, transport] in
            await previous?.value
            guard !Task.isCancelled, self?.stopped == false else { return }
            try? await transport.send(event)
        }
    }

    /// Asks the runtime who is paired. It also pushes a fresh list whenever one comes or goes.
    public func requestDevices() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #else
        let platform = "macOS"
        #endif
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        emit(.deviceList(DeviceListData(devices: [], name:
            "\(platform) \(version.majorVersion).\(version.minorVersion)\(patch)")), in: "")
    }

    /// Forgets a paired device, here and at the relay. Answered with a new list.
    public func removeDevice(_ pub: String) {
        emit(.deviceRemove(DeviceRemoveData(pub: pub)), in: "")
    }

    /// Asks for everything each thread has gained since the last event we hold.
    public func requestSync(includeCurrent: Bool = true) {
        lastSyncFocus = openThread
        emit(
            .syncRequest(SyncRequestData(lastSeen: syncLastSeen, focusThreadId: openThread,
                includeCurrent: includeCurrent ? nil : false)),
            in: ""
        )
    }

    /// Backfill only the opened thread. Its cursor stays separate from routine sync, whose
    /// post-pairing position may already be ahead of the history this request needs.
    private func requestOpenHistory() {
        guard cache != nil, state == .paired, ownerOnline, let id = openThread,
              synced.contains(where: { $0.id == id }), !historyLoaded.contains(id),
              historyInFlight.insert(id).inserted else { return }
        emit(.syncRequest(SyncRequestData(
            lastSeen: historyCursors[id].map { [id: $0] } ?? [:], threadId: id
        )), in: "")
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
        guard !stopped else { return }
        switch update {
        case .peerInfo(let info):
            guard info.isValid else { return }
            peerInfo = info
            cache?.save(peerInfo: info)
        case .compatibility(let compatibility):
            self.compatibility = compatibility
        case .state(let state):
            self.state = state
            if state != .paired {
                ownerOnline = false
                if updateStatus.phase != .none && updateStatus.phase != .installing {
                    updateStatus.phase = .unknown
                    updateStatus.deadline = nil
                }
            }
            historyInFlight.removeAll()
            if state == .paired {
                failure = nil
                linkFailure = nil
                // Pull is truth. Nothing sent while this socket was down was kept for us —
                // thread, device and rule lists live in no thread's log — so every join asks
                // for all of it again rather than trusting whatever was last pushed.
                emit(.threadList(ThreadListData(threads: [])), in: "")
                requestSync()
                requestOpenHistory()
                requestDevices()
                requestRules()
                if ownerOnline { updateControl(.status) }
                resumeResultRequests()
                onPaired?()
                flush()
            }
        case .ownerOnline(let online):
            let wasOnline = ownerOnline
            ownerOnline = online
            if !online && updateStatus.phase != .none && updateStatus.phase != .installing {
                updateStatus.phase = .unknown
                updateStatus.deadline = nil
            }
            if !online { historyInFlight.removeAll() }
            else if !wasOnline { requestOpenHistory() }
            if online {
                resumeResultRequests()
                if state == .paired {
                    updateControl(.status)
                }
            }
            // The Mac waking up is the other half of "there is somewhere to send to".
            if online { flush() }
        case .event(let event):
            switch event.payload {
            case .updateStatus(let data):
                updateStatus = data
                onUpdateStatus?(data)
                if data.phase != .installing { flush() }
            case .updateControl:
                break
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
                persist(threads: synced)
                requestOpenHistory()
                onThreads?()
            case .syncDelta(let data):
                for event in data.current ?? [] { upsert(event, persist: false) }
                for event in data.events {
                    if case .approvalStatus(let status) = event.payload { retireApproval(status) }
                    upsert(event, persist: false)
                    if data.threadId == nil { syncLastSeen[event.threadId] = event.syncCursor ?? event.id }
                    else { historyCursors[event.threadId] = event.syncCursor ?? event.id }
                }
                if let id = data.threadId {
                    historyInFlight.remove(id)
                    if data.more != true { historyLoaded.insert(id) }
                }
                persistEvents(in: Set(data.events.map(\.threadId))
                    .union((data.current ?? []).map(\.threadId))
                    .union(data.threadId.map { [$0] } ?? []))
                if let workingThreadIds = data.workingThreadIds {
                    generating = Set(workingThreadIds)
                }
                if data.more == true {
                    if data.threadId != nil { requestOpenHistory() }
                    else { requestSync(includeCurrent: openThread != lastSyncFocus) }
                }
                else if data.threadId == nil {
                    syncRevision += 1
                    // Counted only once the sync is whole: a background drain is waiting for
                    // exactly this to know it has caught up and may hang up, and a page with
                    // `more` behind it would let it hang up mid-catch-up. See ``drain(timeout:)``.
                    deltas += 1
                }
            // What the model picker offers, sent with every thread list. Not a thread's event.
            case .modelList(let data):
                models = data.models
                agentModels = data.agentModels ?? [:]
            // And where a coding agent can be started, the same way.
            case .projectList(let data):
                projects = data.projects
                projectsRevision += 1
                projectsFailed = false
            // About the devices rather than in a thread, like the thread list above it.
            case .deviceList(let data):
                devices = data.devices
                deviceListRevision += 1
                onDevices?()
            // The stored rules, in answer to `rule_list` and after any change to them. Also
            // not a thread's event: rules are global, which is the whole point of them.
            case .ruleList(let data):
                rules = data.rules
                onRules?()
            case .approvalSettings(let data):
                if let yolo = data.yolo {
                    yoloMode = yolo
                    yoloUntil = yolo ? data.yoloUntil : nil
                }
            case .receipt(let data):
                receipted(data.eventId)
            case .admissionStatus(let data):
                reconcile(data)
            case .stopStatus(let data):
                reconcileStop(data)
                applyEvent(event)
            case .approvalStatus(let data):
                reconcileApproval(data, event: event)
            default:
                applyEvent(event)
            }
        case .failed(let reason):
            flushStreamEvents()
            failure = reason
            linkFailure = reason
        }
    }

    // Internal so reducer tests can feed one synchronous burst, without AsyncStream actor
    // hops stretching the fixture over multiple real display frames under parallel load.
    func applyEvent(_ event: YorozuEvent) {
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
        var coding = thread("Fix the flaky relay test", "Done: the timeout was the test's, not the relay's.", 0.1)
        coding.agent = .claudeCode
        coding.cwd = "/Users/demo/Projects/yorozu"
        var codex = thread("Tidy the icon script", "Rewrote icon-render.sh to take a size.", 2.3)
        codex.agent = .codex
        codex.cwd = "/Users/demo/Projects/tappa"
        synced = [
            thread("Weeknight dinners", "Roast chicken, then stock on Sunday.", 0.02, pinned: true),
            thread("Invoices", "Found the July one in Downloads.", 0.05),
            coding,
            thread("Kyoto in April", "Booked the 9:05 to Kyoto.", 0.2),
            thread("Standup notes", "Summarised yesterday's thread.", 1.1),
            codex,
            thread("Bike service", "Rescheduled for Thursday.", 3.2),
            thread("Tax return", "Filed — the receipt is in Documents.", 40),
        ]
        projects = [
            ProjectFolder(path: "/Users/demo/Projects/yorozu", name: "yorozu", lastUsed: now - 0.1 * day),
            ProjectFolder(path: "/Users/demo/Projects/tappa", name: "tappa", lastUsed: now - 2.3 * day),
            ProjectFolder(path: "/Users/demo/Projects/browsify", name: "browsify"),
            ProjectFolder(path: "/Users/demo/Projects/localtypist", name: "localtypist"),
        ]
        listed = true
    }

    /// Test-only: the models a Mac with two providers configured would publish, and a thread
    /// already put on the second of them — which is what a screenshot of the picker is about.
    public func previewModels(in threadId: String) {
        models = [
            ModelOption(id: "claude/claude-opus-5", label: "claude-opus-5", providerLabel: "Claude", efforts: [.low, .medium, .high]),
            ModelOption(id: "claude/claude-sonnet-5", label: "claude-sonnet-5", providerLabel: "Claude", efforts: [.low, .medium, .high]),
            ModelOption(id: "codex/gpt-5.6", label: "gpt-5.6", providerLabel: "Codex", efforts: [.low, .medium, .high]),
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
        currency: "USD",
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
            maxAmount: 48,
            currency: "USD"
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

    private func applyAnswerState(_ event: YorozuEvent) {
        switch event.payload {
        case .approvalAnswer(let data):
            answered.insert(data.actionId)
            choices[data.actionId] = data.answer
        case .approvalStatus(let data):
            if approvalOutcomes[data.actionId] != .applied || data.status == .applied {
                approvalOutcomes[data.actionId] = data.status
            }
            if data.status == .applied { answered.insert(data.actionId) }
        case .questionAnswer(let data):
            answeredQuestions.insert(data.questionId)
            questionChoices[data.questionId] = data.answer
        default: break
        }
    }

    private func upsert(_ incoming: YorozuEvent, persist: Bool = true) {
        var event = incoming
        if case .toolResult(var data) = event.payload, let offset = data.chunkOffset {
            let key = event.threadId + "\0" + data.callId
            guard var partial = resultChunks[key], partial.offset == offset else { return }
            partial.output += data.output
            if let next = data.nextOffset {
                guard next > offset else { return }
                partial.offset = next
                resultChunks[key] = partial
                emit(.toolResultRequest(ToolResultRequestData(callId: data.callId, offset: next)), in: event.threadId)
                return
            }
            data.output = partial.output
            data.chunkOffset = nil
            data.nextOffset = nil
            data.truncated = nil
            resultChunks.removeValue(forKey: key)
            event.payload = .toolResult(data)
        }
        if case .toolResult(let data) = event.payload, data.truncated != true, data.chunkOffset == nil {
            resultChunks.removeValue(forKey: event.threadId + "\0" + data.callId)
        }
        applyAnswerState(event)
        var thread = timeline(event.threadId).events
        if let index = thread.firstIndex(where: { $0.id == event.id }) {
            if thread[index].clientTs != nil && event.clientTs == nil,
               case .message(let old) = thread[index].payload, old.role == .user,
               case .message(let next) = event.payload, next.role == .user { return }
            if case .message(let old) = thread[index].payload, old.role == .agent,
               case .message(let next) = event.payload, next.role == .agent,
               (old.done == true && next.done != true ||
                old.done != true && next.done != true &&
                    (thread[index].ts > event.ts || thread[index].ts == event.ts && old.text.count > next.text.count) ||
                old.done == true && next.done == true && thread[index].ts > event.ts) { return }
            guard thread[index] != event else { return }
            let timestampChanged = thread[index].ts != event.ts
            let orderingConfirmed = thread[index].clientTs == nil && event.clientTs != nil
            var agentReply = false
            if case .message(let data) = event.payload { agentReply = data.role == .agent }
            thread[index] = event
            if timestampChanged || orderingConfirmed || agentReply {
                // Streamed replies and host-retimed queued messages move to their final place.
                // Insert after ties: a tool result and final can share a millisecond.
                thread.remove(at: index)
                let position = thread.lastIndex(where: { $0.ts <= event.ts }).map { $0 + 1 } ?? 0
                thread.insert(event, at: position)
            }
        } else {
            // A reconnect sync can race a live relay frame. Put the older synced event back
            // where its runtime timestamp belongs instead of preserving network arrival order.
            // Equal timestamps keep arrival order, which also keeps call before result.
            let index = thread.lastIndex(where: { $0.ts <= event.ts }).map { $0 + 1 } ?? 0
            thread.insert(event, at: index)
        }
        timeline(event.threadId).events = thread
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
            if persist { persistEvents(in: [event.threadId]) }
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
        threadMarkdown(thread: thread, events: timeline(thread.id).events)
    }

    /// The thread's title as a list would draw it, for anything that has only an id. Falls back
    /// to the id itself.
    public func title(of threadId: String) -> String {
        threads.first { $0.id == threadId }?.displayTitle ?? threadId
    }
}
