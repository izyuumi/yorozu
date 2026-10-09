import Foundation
import Observation
import UIKit
import YorozuWire

/// The phone's half of docs/ios-relay-contract.md: the one pairing, the `RelayClient` it drives,
/// and the mirror of the Mac's history window (bubbles, topics, tasks, amendments, worker events,
/// read cursor), kept in `MirrorCache` and caught up by change sequence.
@MainActor
@Observable
final class PhoneModel {
    struct Bubble: Identifiable, Equatable, Codable, Sendable {
        let id: String
        let user: Bool
        /// Epoch ms: the Mac's `created` once stored, the phone's clock until then. Orders the list.
        var ts: Int
        var text: String
        /// A `failure` message: drawn with the failure label.
        var failed: Bool
        /// The Mac's message kind (`conversation`, `result`, `failure`, …); nil until stored.
        var kind: String?
        var topicId: String?
        var taskId: String?
        var replyTo: String?
        var notice: NoticeData?
        /// The Mac's change sequence; nil for a sent bubble whose stored copy has not arrived.
        var seq: Int?
        /// A user message: when the Mac started processing it (epoch ms).
        var readAt: Int?
        /// A user message from a phone: the phone's send time (epoch ms).
        var sentAt: Int?
        /// Its files (#316). Optional so a cache written before attachments still loads.
        var attachments: [AttachmentInfo]?

        var files: [AttachmentInfo] { attachments ?? [] }

        init(id: String, user: Bool, ts: Int, text: String, failed: Bool = false,
             kind: String? = nil, topicId: String? = nil, taskId: String? = nil, replyTo: String? = nil,
             notice: NoticeData? = nil, seq: Int? = nil, readAt: Int? = nil, sentAt: Int? = nil,
             attachments: [AttachmentInfo] = []) {
            self.id = id
            self.user = user
            self.ts = ts
            self.text = text
            self.failed = failed
            self.readAt = readAt
            self.sentAt = sentAt
            self.attachments = attachments.isEmpty ? nil : attachments
            self.kind = kind
            self.topicId = topicId
            self.taskId = taskId
            self.replyTo = replyTo
            self.notice = notice
            self.seq = seq
        }

        init(record id: String, ts: Int, _ m: MessageData) {
            self.init(id: id, user: m.role == .user, ts: ts, text: m.text, failed: m.failed == true || m.kind == "failure",
                      kind: m.kind, topicId: m.topicId, taskId: m.taskId, replyTo: m.replyTo, notice: m.notice, seq: m.seq,
                      readAt: m.readAt, sentAt: m.sentAt, attachments: m.attachmentInfos)
        }
    }

    /// A scanned, pasted or tapped code, held until the user has seen its relay and Mac key.
    struct PendingPairing: Identifiable {
        let id = UUID()
        let payload: QrPayload
        /// The Mac this phone is already paired with: a repair rather than a new Mac.
        let repair: Bool

        var relayHost: String { payload.relayHost }
        var fingerprint: String { payload.fingerprint }
    }

    /// The reply to the latest `page_request`: the messages around one message, for display only.
    struct PageReply: Equatable {
        let requestId: String
        let messageId: String
        var bubbles: [Bubble] = []
        var error: String?
    }

    var draft = ""
    /// Files staged in the composer (#316).
    var draftFiles: [DraftFile] = []
    var pendingPairing: PendingPairing?

    // MARK: Attachments (#316)

    /// Thumbnails and opened files.
    let files = AttachmentFiles()
    /// The Mac takes attachments (its peer info); nil until it has said.
    private(set) var attachmentsSupported: Bool?
    /// Uploads and downloads over the pairing's link (relay or direct), moving bytes only while `.paired`.
    @ObservationIgnored private var transfers: AttachmentTransfers?
    @ObservationIgnored private var transferUpdates: Task<Void, Never>?
    /// Incoming events for the transfers, in arrival order.
    @ObservationIgnored private var transferInbox: AsyncStream<YorozuEvent>.Continuation?
    /// Messages whose files are going up now, and how far, 0 to 1.
    private(set) var uploading: Set<String> = []
    private(set) var uploadProgress: [String: Double] = [:]
    /// The offsets the Mac confirmed, per message and file; mirrored in `UploadStore`.
    private var uploadOffsets: [String: [Int]] = [:]

    // MARK: Mirror (the history window)

    /// Every message, by `ts`; `topicId` also files it in its sub-chat.
    private(set) var bubbles: [Bubble] = [] { didSet { if !receiving { rebuildTimeline() } } }
    /// A delta is being applied: the timeline is rebuilt once at its end, not per record.
    @ObservationIgnored private var receiving = false
    private func rebuildTimeline() { timeline = bubbles.filter { !Self.jobOnlyKinds.contains($0.kind ?? "") } }
    /// The main timeline: every message but those that stay in a job's sub-chat (#319), as on the Mac.
    private(set) var timeline: [Bubble] = []
    /// The Mac's job-only kinds (`Message.jobOnlyKinds`) that reach a phone with `jobs-v1`; the run trigger never does.
    static let jobOnlyKinds: Set = ["job_run", "job_input", "job_result", "job_note"]
    private(set) var topics: [String: TopicData] = [:]
    private(set) var tasks: [String: TaskData] = [:]
    private(set) var amendments: [String: AmendmentData] = [:]
    private(set) var workerEvents: [String: WorkerEventData] = [:]
    /// The Mac's read cursor for `main`: the newest message seen on any device.
    private(set) var readCursor: ReadStateData?
    /// The Mac has work running (`workingThreadIds`); nil = status unknown (not connected).
    private(set) var working: Bool?
    /// The secretary is routing a message (`routingThreadIds`); nil = status unknown.
    private(set) var routing: Bool?
    /// The Mac's latest `readiness`; nil = status unknown (not connected) or a Mac that sends none.
    private(set) var readiness: ReadinessData?
    /// Tasks with a `task_control` in flight: their Stop and Retry stay disabled.
    private(set) var controlling: Set<String> = []
    /// The latest `task_control_result` per task.
    private(set) var controlResults: [String: TaskControlResultData] = [:]
    /// The latest search's hits, pages appended; a result for an older request is ignored.
    private(set) var search: SearchResultData?
    private(set) var page: PageReply?

    // MARK: Jobs (#319)

    /// The Mac negotiated `jobs-v1`; nil until it has said. Jobs stay hidden unless true.
    private(set) var jobsSupported: Bool?
    /// The Mac's latest `job_list`.
    private(set) var jobs: [JobListData.Job] = []
    /// `job_control` events awaiting their answer: event id -> job id. Those jobs' actions stay disabled.
    private(set) var jobControls: [String: String] = [:]
    /// The latest refusal per job.
    private(set) var jobRefusals: [String: String] = [:]
    /// The cache was filled with `jobs-v1`, so it holds the job-only messages; without it a cursor skips them.
    private var cacheHasJobs = false
    /// Sub-chats that belong to jobs: reached through Jobs, not the topic list.
    var jobTopicIds: Set<String> { jobsSupported == true ? Set(jobs.compactMap(\.topicId)) : [] }
    func canControlJob(_ id: String) -> Bool { state == .paired && !jobControls.values.contains(id) }

    // MARK: Outbox (#314)

    /// Messages the Mac has not stored, and stored ones kept for their times until Read. Persisted.
    private(set) var outbox: [Outbox.Item] = []
    /// The forward-only marks of messages sent from this phone and not yet Read. `merge()` replaces
    /// bubbles, so marks live here; Read and messages typed on the Mac are read off the stored copy.
    private(set) var marks: [String: MarkState] = [:]
    /// Messages whose frame is on its way to the relay, until `accepted` (or 10 s without one).
    private(set) var inFlight: Set<String> = []
    /// Sent on the link that is up, 10 s without `accepted` (an old relay): still Sending, not waiting.
    private(set) var unconfirmed: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private var inBackground = false
    /// Background time held while messages are still Sending.
    private var backgroundTime: BackgroundTask?

    // MARK: Push (#320)

    /// A tapped push: the main timeline opens at the message its `event` ref names, else at the bottom.
    struct PushOpen: Equatable {
        let id = UUID()
        let ref: String?
    }

    /// The APNs token from `AppDelegate`, given to every `RelayClient` this model makes.
    private var pushToken: String?
    /// For Copy diagnostics: nil until iOS answers, then "token from Apple" or the failure.
    private(set) var pushRegistration: String?
    var pushOpen: PushOpen?
    /// The main timeline is on screen: `willPresent` shows no banner.
    @ObservationIgnored var mainShown = false
    /// A silent push's catch-up is running: going to the background leaves the link to it.
    @ObservationIgnored private var waking = false
    /// The read cursor the delivered pushes were last cleared to.
    @ObservationIgnored private var clearedTo: String?
    /// This phone's last read, which the Mac's cursor may not echo yet.
    @ObservationIgnored private var localRead: String?

    // MARK: Link

    /// The relay has accepted this phone, so the chat shows rather than the pairing screen.
    private(set) var linked = false
    private(set) var state: TransportState = .closed {
        didSet { if (state == .paired) != (oldValue == .paired) { transfersLive() } }
    }
    private(set) var ownerOnline = false
    /// The link's failure; cleared by the next `.paired`.
    private(set) var failure: String? { didSet { noteError(failure) } }
    /// "Update required: …" while the Mac refuses this phone, for the chat's status line.
    private(set) var updateRequired: String?
    /// The latest failure, kept after it clears, for Settings and Copy diagnostics.
    private(set) var lastError: (message: String, at: Date)?
    private(set) var hostName: String?
    /// The Mac's app version, from its peer info.
    private(set) var macVersion: String?
    /// When this phone first joined the Mac (`PairingStore.Stored.pairedAt`).
    private(set) var pairedAt: Date?
    var relayHost: String? { pairing?.relayHost }
    var relayURL: String? { pairing?.relayUrl }
    var fingerprint: String? { pairing?.fingerprint }
    /// The socket the link runs on while joined; Settings diagnostics only, never the chat.
    private(set) var path: TransportPath?
    /// The direct path's last failure and whether iOS withholds Local Network access.
    private(set) var directReport = DirectReport()
    /// The direct-path addresses the Mac last advertised (`PairingStore.Stored.directCandidates`).
    private(set) var candidates: [DirectCandidate] = []
    /// Settings › Connection › "Direct connection (LAN / Tailscale)", off by default. Its own key: v2 shares
    /// v1's defaults domain, and v1's `directConnectionEnabled` means something else.
    private(set) var directEnabled = UserDefaults.standard.bool(forKey: PhoneModel.directKey)
    /// The status saved on going to the background, shown for up to 3 s on return and launch.
    private var heldStatus: ClientConnectionStatus?
    /// This pairing's `onboardingKey` is false: `onboardingDue` once linked.
    private var onboardingPending = false

    private var pairing: QrPayload?
    /// This phone's X25519 session key, base64url: the cache's owner and `device_remove`'s `pub`.
    private var ownPub: String?
    private var relay: RelayClient?
    private var listener: Task<Void, Never>?
    /// Bumped by each `start()` and `suspend()`: a closing listener only delivers send outcomes.
    private var generation = 0
    private var closing: Task<Void, Never>?
    /// `latestSeq` of the last reply page applied whole.
    private var cursor: Int?
    /// A `sync_request` is out and its pages are not all in: the records may be stale.
    private(set) var catchingUp = false
    /// The `afterSeq` of the `sync_request` awaiting its reply page; nil when none is.
    private var requestedAfter: Int?
    private var pageDeadline: Task<Void, Never>?
    private var chunks = ChunkAssembler()
    private var saveTask: Task<Void, Never>?
    private var searchRequestId: String?
    /// The offset of the search page in flight, so a page is never asked for twice.
    private var searchOffset: Int?
    private var heldRelease: Task<Void, Never>?
    private var savedStatus: SavedStatus?

    var hasPairing: Bool { pairing != nil }
    var status: ClientConnectionStatus { ClientConnectionStatus(state: state, ownerOnline: ownerOnline, failure: failure) }
    /// What the chat shows: the saved status for up to 3 s after a return or launch, then `status`.
    var shownStatus: ClientConnectionStatus { heldStatus ?? status }
    /// Send works once linked, the outbox holding the message until it can go, unless the Mac is blocked (nothing could answer).
    var canSend: Bool { linked && readiness?.state != .blocked }
    /// The chat's readiness line while the Mac needs attention or is blocked: the blocking or only item, else the count.
    var readinessReason: String? {
        guard let r = readiness, r.state != .ready else { return nil }
        let first = r.items.first { $0.severity == .blocking } ?? r.items.first { $0.severity == .warning }
        if let first, r.state == .blocked || r.count == 1 { return first.title }
        return String(localized: "\(r.count) items need attention")
    }
    /// The Mac's work state is known: on the link and caught up.
    var statusKnown: Bool { working != nil && !catchingUp }
    /// Stop and Retry: one in flight per task, only while `.paired`.
    func canControl(_ taskId: String) -> Bool { state == .paired && !controlling.contains(taskId) }

    /// Loads the pairing and its cache; the first `resume()` dials.
    init() {
        savedStatus = SavedStatus.load()
        DraftFile.clearAll()
        do {
            if let stored = try PairingStore.loadRequired() { connect(stored) }
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: Pairing

    /// Returns the message the pairing screens show, or nil when the code now waits for confirmation.
    func pair(with text: String) -> String? {
        guard let payload = try? QrPayload.decode(text), Data(base64URLEncoded: payload.macPubkey)?.count == 32 else {
            return String(localized: "Not a Yorozu pairing code.")
        }
        pendingPairing = PendingPairing(payload: payload, repair: payload.macPubkey == pairing?.macPubkey)
        return nil
    }

    /// Tells the old host to forget this phone, then replaces the pairing with a fresh identity for
    /// the confirmed code, wipes the cache and dials. `device_remove` must go first: `RelayClient`
    /// records its channel counter in the pairing's Keychain item before sealing, which fails once
    /// that pairing is replaced.
    func confirm(_ pending: PendingPairing) async {
        pendingPairing = nil
        await sendDeviceRemove()
        let stored = PairingStore.Stored(pairing: pending.payload, identity: .generate())
        do { try PairingStore.save(stored) } catch {
            failure = error.localizedDescription
            return
        }
        disconnect()
        connect(stored)
        // Due until shown. A Repair keeps the host, so its guide is not shown again.
        if !pending.repair, let key = onboardingKey {
            UserDefaults.standard.set(false, forKey: key)
            onboardingPending = true
        }
        start()
    }

    /// The client onboarding is due: a newly added host has linked and the guide has not been shown for this pairing.
    var onboardingDue: Bool { linked && onboardingPending }

    func onboardingShown() {
        if let key = onboardingKey { UserDefaults.standard.set(true, forKey: key) }
        onboardingPending = false
    }

    /// Per pairing, like `pushKey`, under its own v2 name. False while due, true once shown; pairings made before
    /// onboarding existed have none, so are never due.
    private var onboardingKey: String? { ownPub.map { "clientOnboardingShownV2.\($0)" } }

    /// Tells the host to forget this phone (when the link is up; offline it wipes anyway), then wipes.
    /// The send goes first for the same reason as in `confirm`.
    func remove() async {
        await sendDeviceRemove()
        do { try PairingStore.remove() } catch {
            failure = error.localizedDescription
            return
        }
        disconnect()
    }

    private func sendDeviceRemove() async {
        guard state == .paired, let relay, let ownPub else { return }
        try? await relay.send(YorozuEvent(id: UUID().uuidString, threadId: "main", ts: Self.now, agentId: "device",
                                          payload: .deviceRemove(DeviceRemoveData(pub: ownPub))))
    }

    private func connect(_ stored: PairingStore.Stored) {
        let identity = stored.identity.sessionPublicKey
        let pushKey = "\(Self.pushKey).\(identity.base64URLEncodedString())"
        do {
            relay = try RelayClient(
                pairing: stored.pairing, identity: stored.identity, paired: stored.paired == true,
                counters: PairingCounterStorage(ownPublicKey: identity), direct: directEnabled,
                candidates: stored.directCandidates ?? [], deviceName: DeviceModel.name,
                onPaired: { PairingStore.markPaired(expectedIdentity: identity) },
                onPushSent: { UserDefaults.standard.set($0, forKey: pushKey) })
        } catch {
            failure = error.localizedDescription
            return
        }
        let transfers = AttachmentTransfers(send: { [relay] event in try await relay?.send(event) })
        self.transfers = transfers
        files.transfers = transfers
        let (inbox, feed) = AsyncStream<YorozuEvent>.makeStream()
        transferInbox = feed
        transferUpdates = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await event in inbox { await transfers.handle(event) } }
                for await update in transfers.updates { self?.transferred(update) }
                group.cancelAll()
            }
        }
        pairing = stored.pairing
        pairedAt = stored.pairedAt
        candidates = stored.directCandidates ?? []
        ownPub = identity.base64URLEncodedString()
        onboardingPending = onboardingKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Bool } == false
        linked = stored.paired == true
        applyPush()
        if let ownPub, let snapshot = MirrorCache.shared.load(owner: ownPub) { restore(snapshot) }
        if let ownPub, let saved = Outbox.file.load(Outbox.self), saved.owner == ownPub {
            outbox = saved.items
            marks = saved.marks
            // The cache keeps stored messages only: draw the rest from the outbox.
            for item in outbox where !item.stored {
                // Files still in the outbox show from there.
                for (index, info) in (item.files ?? []).enumerated() { files.register(UploadStore.url(item.id, index), for: info) }
                if case .message(let message) = item.event.payload, !bubbles.contains(where: { $0.id == item.id }) {
                    merge(Bubble(id: item.id, user: true, ts: item.event.ts, text: message.text, kind: message.jobId.map { _ in "job_input" },
                                 topicId: item.topicId, attachments: item.files ?? []))
                }
            }
            expireOverdue()
        }
    }

    /// Forgets the pairing's link and its whole mirror, cache file included.
    private func disconnect() {
        // Nothing to wait for: the old link's late events must not reach the next pairing's mirror.
        inFlight = []
        suspend()
        relay = nil
        transferInbox?.finish()
        transferInbox = nil
        transferUpdates?.cancel()
        transferUpdates = nil
        transfers = nil
        files.transfers = nil
        pairing = nil
        if let onboardingKey { UserDefaults.standard.removeObject(forKey: onboardingKey) }
        onboardingPending = false
        ownPub = nil
        linked = false
        outbox.forEach { LocalNotices.cancelExpiry($0.id) }
        PushNotices.update(badge: 0, read: nil)
        localRead = nil
        clearedTo = nil
        outbox = []
        marks = [:]
        Outbox.file.wipe()
        UploadStore.wipe()
        files.wipe()
        uploading = []
        uploadProgress = [:]
        uploadOffsets = [:]
        attachmentsSupported = nil
        jobsSupported = nil
        jobs = []
        jobRefusals = [:]
        cacheHasJobs = false
        draftFiles.forEach { $0.discard() }
        draftFiles = []
        failure = nil
        updateRequired = nil
        hostName = nil
        macVersion = nil
        pairedAt = nil
        path = nil
        directReport = DirectReport()
        candidates = []
        lastError = nil
        clearMirror(keepPending: false)
        cursor = nil
        saveTask?.cancel()
        saveTask = nil
        MirrorCache.shared.wipe()
    }

    // MARK: Connection

    /// Dials unless already dialling; `RelayClient` redials by itself after a drop until `suspend()`.
    func start() {
        guard let relay, listener == nil else { return }
        let closing = closing
        generation += 1
        let generation = generation
        listener = Task { [weak self] in
            await closing?.value
            for await update in await relay.connect() {
                // An unpaired relay's late updates must never reach the next pairing's mirror.
                guard let self, self.relay === relay else { return }
                if generation == self.generation {
                    self.apply(update)
                } else if case .accepted = update {
                    self.apply(update)
                } else if case .event = update {
                    self.apply(update)
                }
            }
        }
    }

    /// Hangs up, so the next `start()` dials afresh rather than trusting a socket iOS froze. A frame
    /// in flight gets up to 5 s for its `accepted` first; the listener runs on until then.
    func suspend() {
        let listener = listener
        self.listener = nil
        generation += 1
        let relay = relay
        let waiting = !inFlight.isEmpty
        closing = Task { [weak self] in
            if waiting { await self?.waitForFlight() }
            listener?.cancel()
            await relay?.close()
            self?.inFlight = []
        }
        state = .closed
        ownerOnline = false
        unconfirmed = []
        unlinked()
    }

    private func waitForFlight() async {
        let end = ContinuousClock.now + .seconds(5)
        while !inFlight.isEmpty, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Going to the background: remember what the chat showed and save the cache. With messages
    /// still Sending, keep the link and flushing on background time; otherwise hang up.
    func enterBackground() {
        savedStatus = SavedStatus(status: shownStatus, time: Date())
        savedStatus?.save()
        flush()
        inBackground = true
        guard sendingCount > 0 else { return waking ? () : suspend() }
        backgroundTime = BackgroundTask("Yorozu outbox") { [weak self] in self?.backgroundExpired() }
        flushOutbox(all: state == .paired)
    }

    /// Background time ran out with messages still Sending: say so, and hang up.
    private func backgroundExpired() {
        backgroundTime = nil
        let count = sendingCount
        if count > 0 { LocalNotices.postWaiting(count) }
        suspend()
    }

    /// In the background, once nothing is Sending: hang up, then give the time back.
    private func finishBackgroundIfDone() {
        guard inBackground, !waking, let held = backgroundTime, sendingCount == 0 else { return }
        backgroundTime = nil
        suspend()
        let closing = closing
        Task {
            await closing?.value
            held.end()
        }
    }

    private var sendingCount: Int { outbox.filter { marks[$0.id] == .sending }.count }

    /// Back in the foreground: show the saved status (if under 10 minutes old) for up to 3 s, and dial
    /// (or redial now instead of waiting out a backoff) unless the link is already up.
    func resume() {
        inBackground = false
        backgroundTime?.end()
        backgroundTime = nil
        LocalNotices.clearWaiting()
        PushNotices.removeBackOnline()
        expireOverdue()
        if let saved = savedStatus {
            savedStatus = nil
            if Date().timeIntervalSince(saved.time) < 600 { hold(saved.status) }
        }
        guard state != .paired else {
            Task { [relay] in await relay?.refreshDirect() }
            return
        }
        guard listener != nil else { return start() }
        Task { [relay] in await relay?.reconnect() }
    }

    /// The direct-path toggle. On tries the Mac's LAN addresses at once, which is when iOS asks for Local
    /// Network access; off closes any direct socket and stays on the relay.
    func setDirect(_ enabled: Bool) {
        directEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.directKey)
        Task { [relay] in await relay?.setDirect(enabled) }
    }

    private static let directKey = "directPathEnabledV2"

    // MARK: Push

    func registerPush(_ token: String) {
        pushToken = token
        pushRegistration = "token from Apple"
        applyPush()
    }

    func pushFailed(_ reason: String) { pushRegistration = "failed: \(reason)" }

    /// The relay learns the token on every relay join; a direct session joins the relay once for a token it has not heard.
    private func applyPush() {
        guard let pushToken, let relay else { return }
        let known = pushOnRelay
        Task { await relay.registerPush(deviceToken: pushToken, relayKnows: known) }
    }

    /// The token the relay last heard, per pairing.
    private static let pushKey = "pushTokenOnRelayV2"

    /// The relay has stored this pairing's current token (`onPushSent`).
    var pushOnRelay: Bool {
        guard let pushToken, let ownPub else { return false }
        return UserDefaults.standard.string(forKey: "\(Self.pushKey).\(ownPub)") == pushToken
    }

    /// A silent push in the background: dial unless a link is up, catch up into the cache, let the outbox resend and
    /// set the badge, within about 25 s. Back in the background it hangs up a link it dialled itself (or one left to it
    /// on the way out); #314's held link hangs up when its sends are done; a foreground link stays. True when
    /// something new arrived.
    func wake() async -> Bool {
        guard relay != nil, linked, !waking else { return false }
        let before = cursor
        waking = true
        let dialled = listener == nil
        start()
        let end = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < end, state != .paired || catchingUp || sendingCount > 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        waking = false
        flush()
        updateBadge()
        if UIApplication.shared.applicationState == .background {
            if backgroundTime != nil { finishBackgroundIfDone() } else if dialled || inBackground { suspend() }
            await closing?.value
        }
        return cursor != before
    }

    func open(pushEvent ref: String?) { pushOpen = PushOpen(ref: ref) }

    /// The main-timeline message a push's `event` ref names.
    func messageId(ref: String) -> String? { timeline.last { YorozuCrypto.threadRef($0.id) == ref }?.id }

    /// The badge is Yorozu's messages after the later of this phone's read and the Mac's cursor, or all of them when
    /// neither is in the timeline. When that read moves, the delivered pushes for messages at or before it go.
    private func updateBadge() {
        let index = [localRead, readCursor?.messageId].compactMap { id in timeline.firstIndex { $0.id == id } }.max()
        let id = index.map { timeline[$0].id }
        let read = index.flatMap { i in id == clearedTo ? nil : Set(timeline[...i].map { YorozuCrypto.threadRef($0.id) }) }
        clearedTo = id
        PushNotices.update(badge: timeline[(index.map { $0 + 1 } ?? 0)...].filter { !$0.user }.count, read: read)
    }

    private func hold(_ status: ClientConnectionStatus) {
        heldStatus = status
        heldRelease?.cancel()
        heldRelease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.heldStatus = nil
        }
    }

    /// A definite outcome replaces the held status at once.
    private func releaseHeldIfSettled() {
        guard heldStatus != nil, status == .connected || status == .failed else { return }
        heldRelease?.cancel()
        heldStatus = nil
    }

    private func apply(_ update: TransportUpdate) {
        switch update {
        case .state(let state):
            self.state = state
            if state != .paired {
                ownerOnline = false
                unlinked()
            }
            if state != .joined && state != .paired { path = nil }
            if state == .joined || state == .paired {
                linked = true
            } else {
                inFlight = []
                unconfirmed = []
            }
            // Mac away: only what is still Sending; the relay already holds the rest.
            if state == .joined { flushOutbox(all: false) }
            if state == .paired { paired() }
        case .accepted(let eventId, let buffered):
            accepted(eventId, buffered: buffered)
        case .ownerOnline(let online):
            ownerOnline = online
        case .peerInfo(let info):
            hostName = info.computerName
            macVersion = info.appVersion
            attachmentsSupported = info.capabilities.contains(AttachmentLimits.capability)
            let advertised = info.directCandidates ?? []
            if advertised != candidates, let ownPub, let identity = Data(base64URLEncoded: ownPub) {
                candidates = advertised
                PairingStore.setCandidates(advertised, expectedIdentity: identity)
            }
        case .path(let path):
            self.path = path
        case .direct(let report):
            directReport = report
        case .compatibility(let compatibility):
            if case .updateRequired(let reason) = compatibility {
                updateRequired = String(localized: "Update required: \(reason)")
            } else {
                updateRequired = nil
            }
            if case .compatible(_, let capabilities) = compatibility {
                jobsSupported = capabilities.contains(JobListData.capability)
                // A cache filled without `jobs-v1` has a cursor past the job-only messages: fill it again from the window.
                if jobsSupported == true, !cacheHasJobs {
                    cacheHasJobs = true
                    cursor = nil
                }
            }
        case .failed(let reason):
            failure = reason
        case .event(let event):
            // The transfers see every event first: attachment answers are theirs, and a receipt ends an upload.
            transferInbox?.yield(event)
            receive(event)
        }
        releaseHeldIfSettled()
    }

    /// Off `.paired`: the flags are unknown, and nothing in flight will be answered.
    private func unlinked() {
        working = nil
        routing = nil
        readiness = nil
        controlling = []
        jobControls = [:]
        searchOffset = nil
        pageDeadline?.cancel()
        pageDeadline = nil
        requestedAfter = nil
        chunks = ChunkAssembler()
    }

    /// The relay never buffers Mac -> phone frames, so every `.paired` catches up, and resends every
    /// message the Mac has not stored (it dedupes by id).
    private func paired() {
        // `PairingStore.markPaired` stamps the first join; mirror it rather than reread the Keychain.
        if pairedAt == nil { pairedAt = Date() }
        failure = nil
        updateRequired = nil
        catchingUp = true
        requestSync()
        // The relay dropped a page request that went out before the link fell: ask again.
        if let page, page.bubbles.isEmpty, page.error == nil { Task { await requestPage() } }
        flushOutbox(all: true)
    }

    /// Asks for the changes after the cursor, and again after 15 s with neither a reply page nor a chunk.
    private func requestSync() {
        requestedAfter = cursor ?? 0
        let event = YorozuEvent(id: UUID().uuidString, threadId: "main", ts: Self.now, agentId: "device",
                                payload: .syncRequest(SyncRequestData(threadId: "main", afterSeq: cursor)))
        armDeadline()
        Task { [relay] in try? await relay?.send(event) }
    }

    private func armDeadline() {
        pageDeadline?.cancel()
        pageDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.state == .paired else { return }
            self.requestSync()
        }
    }

    // MARK: Sending

    /// Into the outbox: the bubble shows at once with Sending, the draft clears, and the flush sends it
    /// now if the relay is reachable. A message with files keeps their protected copies in `UploadStore`,
    /// and its text waits with them as one unit.
    func send() {
        let text = draft
        let picked = draftFiles
        guard canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !picked.isEmpty else { return }
        let ts = Self.now
        let id = UUID().uuidString
        var infos: [AttachmentInfo] = []
        if !picked.isEmpty {
            do {
                infos = try UploadStore.store(picked, for: id)
            } catch {
                attachFailure = String(localized: "Couldn’t keep the files for sending. Try again.")
                return
            }
            for (index, info) in infos.enumerated() { files.register(UploadStore.url(id, index), for: info) }
            uploadOffsets[id] = Array(repeating: 0, count: infos.count)
            UploadStore.setOffsets(id, uploadOffsets[id] ?? [])
        }
        let event = YorozuEvent(id: id, threadId: "main", ts: ts, agentId: "device",
                                payload: .message(MessageData(role: .user, text: text, admissionDeadline: ts + Outbox.lifetime)))
        draft = ""
        draftFiles = []
        enqueue(Outbox.Item(event: event, sentAt: ts, files: infos.isEmpty ? nil : infos), Bubble(id: id, user: true, ts: ts, text: text, attachments: infos))
    }

    /// A job's own input (#319): through the outbox like any message, filed in the job's sub-chat. Text only.
    func send(_ text: String, toJob job: String, topic: String) {
        guard canSend, jobsSupported == true, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let ts = Self.now
        let event = YorozuEvent(id: UUID().uuidString, threadId: "main", ts: ts, agentId: "device",
                                payload: .message(MessageData(role: .user, text: text, admissionDeadline: ts + Outbox.lifetime, jobId: job)))
        enqueue(Outbox.Item(event: event, sentAt: ts, topicId: topic),
                Bubble(id: event.id, user: true, ts: ts, text: text, kind: "job_input", topicId: topic))
    }

    private func enqueue(_ item: Outbox.Item, _ bubble: Bubble) {
        outbox.append(item)
        setMark(item.id, .sending)
        merge(bubble)
        saveOutbox()
        queued()
    }

    /// Pause, Resume, Run now or Delete one job. One at a time per job, only while `.paired`, never queued; the
    /// Mac's `admission_status` for the event ends it, and a refusal is kept for the job's row.
    func control(job: String, _ action: JobControlData.Action) async {
        guard canControlJob(job) else { return }
        let id = UUID().uuidString
        jobControls[id] = job
        jobRefusals[job] = nil
        guard let relay else { jobControls[id] = nil; return }
        do {
            try await relay.send(YorozuEvent(id: id, threadId: "main", ts: Self.now, agentId: "device",
                                             payload: .jobControl(JobControlData(jobId: job, action: action))))
        } catch {
            jobControls[id] = nil
        }
    }

    /// "Send as Text File": a draft over the message limit goes as a `.txt` file, with any staged files.
    func sendAsTextFile() {
        guard draftFiles.count < AttachmentLimits.maxCount else { return }
        do {
            draftFiles.append(try DraftFile.textFile(draft))
        } catch {
            attachFailure = String(localized: "Couldn’t keep the files for sending. Try again.")
            return
        }
        draft = ""
        send()
    }

    /// Why the last send with files did not go; the composer shows it.
    var attachFailure: String?

    /// Not delivered → Sending: the same id with a new `ts` and deadline.
    func resend(_ id: String) {
        guard marks[id] == .notDelivered, let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        let ts = Self.now
        var item = outbox[index]
        item.event.ts = ts
        if case .message(var message) = item.event.payload {
            message.admissionDeadline = ts + Outbox.lifetime
            item.event.payload = .message(message)
        }
        item.sentAt = ts
        item.deliveredAt = nil
        item.buffered = false
        item.reason = nil
        outbox[index] = item
        setMark(id, .sending, resend: true)
        if var bubble = bubbles.first(where: { $0.id == id }), bubble.seq == nil {
            bubble.ts = ts
            merge(bubble)
        }
        saveOutbox()
        queued()
    }

    /// Removes a Not delivered message: its bubble, its outbox item and its notification.
    func delete(_ id: String) {
        guard marks[id] == .notDelivered else { return }
        outbox.removeAll { $0.id == id }
        marks[id] = nil
        bubbles.removeAll { $0.id == id && $0.seq == nil }
        LocalNotices.cancelExpiry(id)
        UploadStore.remove(id)
        uploadOffsets[id] = nil
        uploadProgress[id] = nil
        saveOutbox()
    }

    /// The mark and times of a user message; nil for Yorozu's.
    func delivery(of bubble: Bubble) -> Delivery? {
        guard bubble.user else { return nil }
        let item = outbox.first { $0.id == bubble.id }
        let state: MarkState
        if bubble.readAt != nil {
            state = .read
        } else if let mark = marks[bubble.id] {
            state = mark
        } else if bubble.seq != nil {
            state = .delivered
        } else {
            return nil
        }
        let stored = bubble.seq != nil
        let sentAt = item?.sentAt ?? bubble.sentAt ?? bubble.ts
        let uploading = state == .sending && uploading.contains(bubble.id)
        return Delivery(
            state: state, inFlight: state == .sending && inFlight.contains(bubble.id) || uploading,
            sent: state == .sending && (inFlight.contains(bubble.id) || unconfirmed.contains(bubble.id)) || uploading, sentAt: sentAt,
            deliveredAt: item?.deliveredAt,
            expiresAt: item?.buffered == true && !stored && item?.stored == false ? sentAt + Outbox.lifetime : nil,
            receivedAt: stored ? bubble.ts : nil, readAt: bubble.readAt, reason: item?.reason,
            files: item?.files?.count ?? 0, upload: uploading ? uploadProgress[bubble.id] ?? 0 : nil,
            onHost: stored || item?.stored == true)
    }

    /// A message has to wait in the outbox when the relay is out of reach: the moment to ask for
    /// notification permission (#314 open question 4).
    private func queued() {
        if state != .joined && state != .paired { LocalNotices.requestPermission() }
        flushOutbox(all: false)
    }

    /// One flush at a time, in order. `all` (on `.paired`): every message the Mac has not stored;
    /// otherwise only those still Sending.
    private func flushOutbox(all: Bool) {
        let previous = flushTask
        flushTask = Task { [weak self] in
            await previous?.value
            await self?.runFlush(all: all)
        }
    }

    private func runFlush(all: Bool) async {
        expireOverdue()
        guard let relay, state == .joined || state == .paired else { return }
        let time = BackgroundTask("Yorozu send")
        defer { time.end() }
        let due = outbox.filter {
            !$0.stored && !inFlight.contains($0.id) && (marks[$0.id] == .sending || (all && marks[$0.id] == .delivered))
        }.map(\.id)
        for id in due {
            guard self.relay === relay, state == .joined || state == .paired else { break }
            guard let item = outbox.first(where: { $0.id == id }), !item.stored,
                  marks[id] == .sending || marks[id] == .delivered else { continue }
            if let attached = item.files, !attached.isEmpty {
                // Only over a live session with the Mac: the relay's buffer is too small for files.
                guard state == .paired else { continue }
                // A later text message may go first: it never waits behind an upload that cannot run.
                await upload(item, attached)
                continue
            }
            inFlight.insert(id)
            do {
                try await relay.send(item.event)
                settle(id)
            } catch {
                inFlight.remove(id)
                unconfirmed.remove(id)
                LocalNotices.requestPermission()
            }
        }
        finishBackgroundIfDone()
    }

    /// Hands one message's files to `AttachmentTransfers`, from the offsets the Mac last confirmed. The actor
    /// uploads while `.paired`, then sends the commit; the usual `receipt` or `admission_status` settles it.
    private func upload(_ item: Outbox.Item, _ attached: [AttachmentInfo]) async {
        let id = item.id
        // A Mac that has not advertised attachments never sees an `attachment_*` kind; the message waits.
        guard let transfers, attachmentsSupported == true, !uploading.contains(id), case .message(let message) = item.event.payload else { return }
        let offsets = uploadOffsets[id] ?? UploadStore.offsets(id, count: attached.count)
        let files = attached.enumerated().compactMap { index, info in
            info.sha256.map {
                AttachmentTransfers.Upload.File(url: UploadStore.url(id, index),
                                                descriptor: AttachmentDescriptor(name: info.name, mime: info.mime, bytes: info.bytes, sha256: $0),
                                                offset: offsets[index])
            }
        }
        guard UploadStore.exists(id, count: attached.count), files.count == attached.count else {
            notDelivered(id, reason: AttachmentLimits.reason(AttachmentTransfers.localFileMissing))
            return
        }
        uploadOffsets[id] = offsets
        uploadProgress[id] = Self.fraction(offsets, attached)
        uploading.insert(id)
        await transfers.upload(AttachmentTransfers.Upload(messageId: id, threadId: item.event.threadId, ts: item.event.ts,
                                                          text: message.text, admissionDeadline: item.deadline, files: files))
    }

    /// `AttachmentTransfers.updates`: offsets to persist, a failed upload, and downloads for the cache.
    private func transferred(_ update: AttachmentTransfers.Update) {
        switch update {
        case .uploadProgress(let id, let index, let offset):
            if let attached = outbox.first(where: { $0.id == id })?.files { uploaded(id, index, offset, attached) }
        case .uploadCommitted:
            break // Sending until the receipt or the stored copy.
        case .uploadFailed(let id, let reason):
            uploading.remove(id)
            guard let item = outbox.first(where: { $0.id == id }), !item.stored else { return }
            // A corrupt or expired staging starts over from zero on Resend.
            uploadOffsets[id] = Array(repeating: 0, count: item.files?.count ?? 0)
            UploadStore.setOffsets(id, uploadOffsets[id] ?? [])
            notDelivered(id, reason: AttachmentLimits.reason(reason))
        default:
            files.apply(update)
        }
    }

    /// Bytes move only on `.paired`; anything else stops the frames in flight until the next one.
    private func transfersLive() {
        if state != .paired { uploading = [] }
        Task { [weak self] in
            guard let self, let transfers = self.transfers else { return }
            await transfers.setLive(self.state == .paired)
        }
    }

    /// The Mac confirmed a chunk: the offset is fsynced before the next one goes.
    private func uploaded(_ id: String, _ index: Int, _ next: Int, _ attached: [AttachmentInfo]) {
        guard var offsets = uploadOffsets[id], offsets.indices.contains(index) else { return }
        offsets[index] = next
        uploadOffsets[id] = offsets
        UploadStore.setOffsets(id, offsets)
        uploadProgress[id] = Self.fraction(offsets, attached)
    }

    private static func fraction(_ offsets: [Int], _ attached: [AttachmentInfo]) -> Double {
        let total = attached.reduce(0) { $0 + $1.bytes }
        return total > 0 ? Double(zip(offsets, attached).reduce(0) { $0 + min($1.0, $1.1.bytes) }) / Double(total) : 0
    }

    /// An old relay never answers `accepted`: the mark stops spinning after 10 s and stays Sending,
    /// marked sent while that link is up.
    private func settle(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.inFlight.remove(id) != nil { self?.unconfirmed.insert(id) }
        }
    }

    /// The expiry notification only for a frame the relay holds for an away Mac, and the moment to
    /// ask for permission to show it.
    private func accepted(_ id: String, buffered: Bool) {
        inFlight.remove(id)
        unconfirmed.remove(id)
        guard marks[id] == .sending, let index = outbox.firstIndex(where: { $0.id == id }), !outbox[index].stored else { return }
        outbox[index].deliveredAt = Self.now
        outbox[index].buffered = buffered
        setMark(id, .delivered)
        if buffered {
            LocalNotices.requestPermission()
            LocalNotices.scheduleExpiry(id)
        }
        saveOutbox()
        finishBackgroundIfDone()
    }

    /// The Mac has the message: a `receipt`, or its stored copy (`read` once it has `readAt`). The item
    /// leaves the send queue; at Read its times go too.
    private func stored(_ id: String, read: Bool) {
        guard marks[id] != nil || outbox.contains(where: { $0.id == id }) else { return }
        inFlight.remove(id)
        unconfirmed.remove(id)
        // The relay no longer holds it, so it can no longer expire there.
        LocalNotices.cancelExpiry(id)
        // Its files are on the Mac: the outbox copies become cached files.
        if uploading.remove(id) != nil { Task { [transfers] in await transfers?.cancelUpload(id) } }
        if let attached = outbox.first(where: { $0.id == id })?.files, uploadOffsets[id] != nil || UploadStore.exists(id, count: attached.count) {
            files.adopt(attached, from: id)
            UploadStore.remove(id)
            uploadOffsets[id] = nil
            uploadProgress[id] = nil
        }
        if read {
            marks[id] = nil
            outbox.removeAll { $0.id == id }
        } else {
            if let index = outbox.firstIndex(where: { $0.id == id }) { outbox[index].stored = true }
            setMark(id, .delivered)
        }
        saveOutbox()
        finishBackgroundIfDone()
    }

    private func notDelivered(_ id: String, reason: String?) {
        inFlight.remove(id)
        if uploading.remove(id) != nil { Task { [transfers] in await transfers?.cancelUpload(id) } }
        unconfirmed.remove(id)
        guard let index = outbox.firstIndex(where: { $0.id == id }), MarkState.allows(marks[id], .notDelivered) else { return }
        outbox[index].reason = reason
        setMark(id, .notDelivered)
        saveOutbox()
        finishBackgroundIfDone()
    }

    /// Never accepted by the relay and past its deadline: Not delivered here, without the Mac.
    private func expireOverdue() {
        let now = Self.now
        for item in outbox where marks[item.id] == .sending && item.deliveredAt == nil && !item.stored && now > item.deadline {
            notDelivered(item.id, reason: String(localized: "This device couldn’t send it within 24 hours."))
        }
    }

    /// The forward-only rule; leaving Delivered cancels the expiry notification `accepted` scheduled.
    private func setMark(_ id: String, _ new: MarkState, resend: Bool = false) {
        let old = marks[id]
        guard resend || MarkState.allows(old, new) else { return }
        marks[id] = new
        switch new {
        case .delivered:
            break
        case .sending, .read:
            LocalNotices.cancelExpiry(id)
        case .notDelivered:
            LocalNotices.cancelExpiry(id)
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Message not delivered"))
        }
    }

    private func saveOutbox() {
        guard let ownPub else { return }
        Outbox.file.save(Outbox(owner: ownPub, items: outbox, marks: marks))
    }

    /// Stop or Retry one task. One per tap, only while `.paired`, never queued or resent; returns
    /// false when it did not go. The task stays in `controlling` until its result or a change to it.
    @discardableResult
    func control(_ taskId: String, _ action: TaskControlData.Action) async -> Bool {
        guard canControl(taskId) else { return false }
        controlling.insert(taskId)
        let ok = await sendNow(.taskControl(TaskControlData(requestId: UUID().uuidString, taskId: taskId, action: action)))
        if !ok { controlling.remove(taskId) }
        return ok
    }

    /// Full-history search; `offset` continues the current one (hits are appended). Needs `.paired`.
    @discardableResult
    func search(_ query: String, offset: Int? = nil) async -> Bool {
        guard state == .paired else { return false }
        if offset != nil, offset == searchOffset { return false }
        let requestId = UUID().uuidString
        searchRequestId = requestId
        searchOffset = offset
        if offset == nil { search = nil }
        return await sendNow(.searchRequest(SearchRequestData(requestId: requestId, query: query, offset: offset)))
    }

    /// The page around one message (a search hit outside the cache), into `page`. Needs `.paired`;
    /// a request the relay dropped is asked again on the next `.paired`, one that did not go is forgotten.
    @discardableResult
    func loadPage(around messageId: String) async -> Bool {
        guard state == .paired else { return false }
        page = PageReply(requestId: UUID().uuidString, messageId: messageId)
        return await requestPage()
    }

    private func requestPage() async -> Bool {
        guard let held = page else { return false }
        let ok = await sendNow(.pageRequest(PageRequestData(requestId: held.requestId, threadId: "main", messageId: held.messageId)))
        if !ok, page?.requestId == held.requestId { page = nil }
        return ok
    }

    /// Moves the Mac's read cursor to the newest message seen. Only while `.paired`; not queued.
    func markRead(_ messageId: String) async {
        guard state == .paired else { return }
        localRead = messageId
        updateBadge()
        _ = await sendNow(.readState(ReadStateData(threadId: "main", messageId: messageId)))
    }

    private func sendNow(_ payload: YorozuEvent.Payload) async -> Bool {
        guard let relay else { return false }
        do {
            try await relay.send(YorozuEvent(id: UUID().uuidString, threadId: "main", ts: Self.now, agentId: "device", payload: payload))
            return true
        } catch {
            return false
        }
    }

    // MARK: Receiving

    private func receive(_ event: YorozuEvent) {
        switch event.payload {
        case .chunk(let chunk):
            // A long set is progress: the reply deadline restarts with each chunk.
            if requestedAfter != nil { armDeadline() }
            if let whole = chunks.add(chunk) { receive(whole) }
        case .admissionStatus(let status) where jobControls[status.eventId] != nil:
            if let job = jobControls.removeValue(forKey: status.eventId), status.status == .rejected { jobRefusals[job] = status.reason }
        case .jobList(let list):
            jobs = list.jobs
        case .receipt(let receipt):
            stored(receipt.eventId, read: false)
        case .admissionStatus(let status) where status.status == .expired:
            // One meaning, said in the phone's language rather than the Mac's English reason.
            notDelivered(status.eventId, reason: String(localized: "The host was offline for more than 24 hours."))
        case .admissionStatus(let status) where status.status == .rejected:
            notDelivered(status.eventId, reason: status.reason)
        case .syncDelta(let delta):
            receive(delta)
        case .readiness(let readiness):
            self.readiness = readiness
        case .taskControlResult(let result):
            controlling.remove(result.taskId)
            controlResults[result.taskId] = result
        case .searchResult(let result) where result.requestId == searchRequestId:
            searchOffset = nil
            // A new query cleared `search`, so anything held is an earlier page of this one.
            if var held = search {
                held.requestId = result.requestId
                held.hits += result.hits
                held.total = result.total
                held.nextOffset = result.nextOffset
                held.error = result.error
                search = held
            } else {
                search = result
            }
        default:
            break
        }
    }

    /// The contract's phone rules for a reply page, a live update or a page reply.
    private func receive(_ delta: SyncDeltaData) {
        receiving = true
        defer { receiving = false; rebuildTimeline(); updateBadge() }
        if let working = delta.workingThreadIds { self.working = working.contains("main") }
        if let routing = delta.routingThreadIds { self.routing = routing.contains("main") }
        if let requestId = delta.requestId {
            guard requestId == page?.requestId else { return }
            pageReply(delta)
            return
        }
        let reply = requestedAfter != nil && (delta.reset == true || (delta.afterSeq ?? 0) == requestedAfter)
        if reply {
            // An error page keeps the cursor; the deadline asks again.
            guard delta.error == nil else { return }
            pageDeadline?.cancel()
            pageDeadline = nil
            requestedAfter = nil
            if delta.reset == true { clearMirror(keepPending: true) }
            delta.events.forEach(applyRecord)
            if let latest = delta.latestSeq { cursor = latest }
            if delta.more == true { requestSync() } else { catchingUp = false }
        } else {
            delta.events.forEach(applyRecord)
            if !catchingUp, let latest = delta.latestSeq {
                if (delta.afterSeq ?? 0) <= (cursor ?? 0) {
                    cursor = max(cursor ?? 0, latest)
                } else if state == .paired {
                    // A live update was missed: catch up now rather than at the next `.paired`.
                    catchingUp = true
                    requestSync()
                }
            }
        }
        scheduleSave()
    }

    /// Messages held already are updated in place; the rest stay out of the timeline and the cache.
    private func pageReply(_ delta: SyncDeltaData) {
        guard var reply = page else { return }
        reply.error = delta.error
        for event in delta.events {
            guard case .message(let message) = event.payload else { continue }
            let bubble = Bubble(record: event.id, ts: event.ts, message)
            reply.bubbles.append(bubble)
            if bubbles.contains(where: { $0.id == event.id }) { applyRecord(event) }
        }
        page = reply
    }

    /// The upsert rule: a held record is replaced only by one with a higher `seq` (a `worker_event` too: its shared
    /// images arrive later, re-stamped).
    private func applyRecord(_ event: YorozuEvent) {
        switch event.payload {
        case .message(let message):
            let held = bubbles.first { $0.id == event.id }
            guard held?.seq == nil || (held?.seq ?? 0) < (message.seq ?? 0) else { return }
            merge(Bubble(record: event.id, ts: event.ts, message))
            if message.role == .user, message.seq != nil { stored(event.id, read: message.readAt != nil) }
        case .topic(let topic):
            if (topics[topic.id]?.seq ?? -1) < topic.seq { topics[topic.id] = topic }
        case .task(let task):
            if (tasks[task.id]?.seq ?? -1) < task.seq {
                tasks[task.id] = task
                controlling.remove(task.id)
                // The result answered the record this replaces.
                controlResults[task.id] = nil
            }
        case .amendment(let amendment):
            if (amendments[amendment.id]?.seq ?? -1) < amendment.seq { amendments[amendment.id] = amendment }
        case .workerEvent(let workerEvent):
            if (workerEvents[workerEvent.id]?.seq ?? -1) < workerEvent.seq { workerEvents[workerEvent.id] = workerEvent }
        case .readState(let read) where read.threadId == "main":
            if (readCursor?.seq ?? -1) < (read.seq ?? 0) { readCursor = read }
        default:
            break
        }
    }

    /// Placed by `ts`, ties in arrival order: pages, live updates and sends can interleave out of Mac order.
    private func merge(_ bubble: Bubble) {
        bubbles.removeAll { $0.id == bubble.id }
        bubbles.insert(bubble, at: bubbles.lastIndex { $0.ts <= bubble.ts }.map { $0 + 1 } ?? 0)
    }

    // MARK: Cache

    /// `keepPending`: sent bubbles whose stored copy has not arrived survive a `reset`.
    private func clearMirror(keepPending: Bool) {
        bubbles = keepPending ? bubbles.filter { $0.seq == nil } : []
        topics = [:]
        tasks = [:]
        amendments = [:]
        workerEvents = [:]
        readCursor = nil
        page = nil
        search = nil
        controlResults = [:]
    }

    private func restore(_ snapshot: MirrorCache.Snapshot) {
        cursor = snapshot.cursor
        readCursor = snapshot.readCursor
        bubbles = snapshot.messages.sorted { $0.ts < $1.ts }
        topics = Dictionary(snapshot.topics.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        tasks = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        amendments = Dictionary(snapshot.amendments.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        workerEvents = Dictionary(snapshot.workerEvents.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cacheHasJobs = snapshot.jobs == true
        trim()
    }

    /// Records arrive often while workers run; one write a second is enough.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Trims to the window and writes the cache now.
    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let ownPub else { return }
        trim()
        MirrorCache.shared.save(MirrorCache.Snapshot(
            owner: ownPub, cursor: cursor, readCursor: readCursor,
            messages: bubbles.filter { $0.seq != nil }, topics: Array(topics.values), tasks: Array(tasks.values),
            amendments: Array(amendments.values), workerEvents: Array(workerEvents.values), jobs: cacheHasJobs))
    }

    /// The history window by the phone's clock and count: the newest 500 stored main-timeline messages
    /// plus every one younger than 30 days (job-only ones only then), and the topics, tasks, amendments
    /// and worker events they reach, plus unsuppressed active or uncertain tasks (the Mac's work scope).
    private func trim() {
        let cutoff = Self.now - Self.windowDays * 86_400_000
        let stored = bubbles.filter { $0.seq != nil }
        let newest = Set(stored.filter { !Self.jobOnlyKinds.contains($0.kind ?? "") }.suffix(Self.windowCount).map(\.id))
        bubbles.removeAll { $0.seq != nil && $0.ts < cutoff && !newest.contains($0.id) }
        let kept = Set(bubbles.map(\.id))
        let keptTasks = Set(bubbles.compactMap(\.taskId))
        tasks = tasks.filter {
            kept.contains($0.value.messageId) || keptTasks.contains($0.key) || $0.value.created >= cutoff
                || (!$0.value.suppressed && Self.liveStates.contains($0.value.state))
        }
        let topicIds = Set(bubbles.compactMap(\.topicId)).union(tasks.values.map(\.topicId))
        topics = topics.filter { topicIds.contains($0.key) || $0.value.created >= cutoff }
        amendments = amendments.filter { tasks[$0.value.taskId] != nil }
        workerEvents = workerEvents.filter { tasks[$0.value.taskId] != nil }
        // A stored message that left the window is never Read here: its times go with it.
        let before = outbox.count
        outbox.removeAll { $0.stored && !kept.contains($0.id) }
        let queued = Set(outbox.map(\.id))
        let pruned = marks.keys.filter { !kept.contains($0) && !queued.contains($0) }
        pruned.forEach { marks[$0] = nil; LocalNotices.cancelExpiry($0) }
        if outbox.count != before || !pruned.isEmpty { saveOutbox() }
    }

    private static let windowCount = 500
    private static let windowDays = 30
    private static let liveStates: Set = ["queued", "working", "amendment_pending", "cancellation_requested", "uncertain"]
    private static var now: Int { Int(Date().timeIntervalSince1970 * 1000) }

    private func noteError(_ message: String?) {
        if let message { lastError = (message, Date()) }
    }
}

extension QrPayload {
    var relayHost: String { URLComponents(string: relayUrl)?.host ?? relayUrl }
}

/// The chat's status when the app last went to the background.
private struct SavedStatus: Codable {
    var status: ClientConnectionStatus
    var time: Date

    private static let key = "lastConnectionStatus"

    static func load() -> SavedStatus? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(SavedStatus.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    enum CodingKeys: String, CodingKey { case status, time }

    init(status: ClientConnectionStatus, time: Date) {
        self.status = status
        self.time = time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        switch try c.decode(String.self, forKey: .status) {
        case "connected": status = .connected
        case "hostOffline": status = .hostOffline
        case "failed": status = .failed
        case "offline": status = .offline
        default: status = .connecting
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode("\(status)", forKey: .status)
    }
}
