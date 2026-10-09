import Foundation
import Observation
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
        /// Refused by the Mac, or a `failure` message: drawn with the failure label.
        var failed: Bool
        /// Why the Mac refused a message, shown under it as is.
        var reason: String?
        /// The Mac's message kind (`conversation`, `result`, `failure`, …); nil until stored.
        var kind: String?
        var topicId: String?
        var taskId: String?
        var replyTo: String?
        var notice: NoticeData?
        /// The Mac's change sequence; nil for a sent bubble whose stored copy has not arrived.
        var seq: Int?

        init(id: String, user: Bool, ts: Int, text: String, failed: Bool = false, reason: String? = nil,
             kind: String? = nil, topicId: String? = nil, taskId: String? = nil, replyTo: String? = nil,
             notice: NoticeData? = nil, seq: Int? = nil) {
            self.id = id
            self.user = user
            self.ts = ts
            self.text = text
            self.failed = failed
            self.reason = reason
            self.kind = kind
            self.topicId = topicId
            self.taskId = taskId
            self.replyTo = replyTo
            self.notice = notice
            self.seq = seq
        }

        init(record id: String, ts: Int, _ m: MessageData) {
            self.init(id: id, user: m.role == .user, ts: ts, text: m.text, failed: m.failed == true || m.kind == "failure",
                      kind: m.kind, topicId: m.topicId, taskId: m.taskId, replyTo: m.replyTo, notice: m.notice, seq: m.seq)
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
    var pendingPairing: PendingPairing?

    // MARK: Mirror (the history window)

    /// The main timeline, by `ts`. Every message goes here; `topicId` also files it in its sub-chat.
    private(set) var bubbles: [Bubble] = []
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
    /// Tasks with a `task_control` in flight: their Stop and Retry stay disabled.
    private(set) var controlling: Set<String> = []
    /// The latest `task_control_result` per task.
    private(set) var controlResults: [String: TaskControlResultData] = [:]
    /// The latest search's hits, pages appended; a result for an older request is ignored.
    private(set) var search: SearchResultData?
    private(set) var page: PageReply?

    // MARK: Link

    private(set) var sending = false
    /// The relay has accepted this phone, so the chat shows rather than the pairing screen.
    private(set) var linked = false
    private(set) var state: TransportState = .closed
    private(set) var ownerOnline = false
    /// The link's failure; cleared by the next `.paired`.
    private(set) var failure: String? { didSet { noteError(failure) } }
    /// "Update required: …" while the Mac refuses this phone, for the chat's status line.
    private(set) var updateRequired: String?
    /// Why the last send did not go; the draft is still in the composer.
    private(set) var sendError: String? { didSet { noteError(sendError) } }
    /// The latest failure or send error, kept after it clears, for Settings and Copy diagnostics.
    private(set) var lastError: (message: String, at: Date)?
    private(set) var hostName: String?
    /// The Mac's app version, from its peer info.
    private(set) var macVersion: String?
    /// When this phone first joined the Mac (`PairingStore.Stored.pairedAt`).
    private(set) var pairedAt: Date?
    var relayHost: String? { pairing?.relayHost }
    var fingerprint: String? { pairing?.fingerprint }
    /// The status saved on going to the background, shown for up to 3 s on return and launch.
    private var heldStatus: ClientConnectionStatus?

    private var pairing: QrPayload?
    /// This phone's X25519 session key, base64url: the cache's owner and `device_remove`'s `pub`.
    private var ownPub: String?
    private var relay: RelayClient?
    private var listener: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    /// Messages without a `receipt` or `admission_status` yet, resent on every `.paired`. The Mac
    /// dedupes by id, so a resend is never a second message.
    private var unreceipted: [YorozuEvent] = []
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
    var canSend: Bool { state == .paired && !sending }
    /// The Mac's work state is known: on the link and caught up.
    var statusKnown: Bool { working != nil && !catchingUp }
    /// Stop and Retry: one in flight per task, only while `.paired`.
    func canControl(_ taskId: String) -> Bool { state == .paired && !controlling.contains(taskId) }

    /// Loads the pairing and its cache; the first `resume()` dials.
    init() {
        savedStatus = SavedStatus.load()
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
        start()
    }

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
        do {
            relay = try RelayClient(
                pairing: stored.pairing, identity: stored.identity, paired: stored.paired == true,
                counters: PairingCounterStorage(ownPublicKey: identity), deviceName: DeviceModel.name,
                onPaired: { PairingStore.markPaired(expectedIdentity: identity) })
        } catch {
            failure = error.localizedDescription
            return
        }
        pairing = stored.pairing
        pairedAt = stored.pairedAt
        ownPub = identity.base64URLEncodedString()
        linked = stored.paired == true
        if let ownPub, let snapshot = MirrorCache.shared.load(owner: ownPub) { restore(snapshot) }
    }

    /// Forgets the pairing's link and its whole mirror, cache file included.
    private func disconnect() {
        suspend()
        relay = nil
        pairing = nil
        ownPub = nil
        linked = false
        unreceipted = []
        failure = nil
        updateRequired = nil
        sendError = nil
        hostName = nil
        macVersion = nil
        pairedAt = nil
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
        listener = Task { [weak self] in
            await closing?.value
            for await update in await relay.connect() {
                self?.apply(update)
            }
        }
    }

    /// Hangs up, so the next `start()` dials afresh rather than trusting a socket iOS froze.
    func suspend() {
        listener?.cancel()
        listener = nil
        let relay = relay
        closing = Task { await relay?.close() }
        state = .closed
        ownerOnline = false
        unlinked()
    }

    /// Going to the background: remember what the chat showed, save the cache and hang up.
    func enterBackground() {
        savedStatus = SavedStatus(status: shownStatus, time: Date())
        savedStatus?.save()
        flush()
        suspend()
    }

    /// Back in the foreground: show the saved status (if under 10 minutes old) for up to 3 s, and dial
    /// (or redial now instead of waiting out a backoff) unless the link is already up.
    func resume() {
        if let saved = savedStatus {
            savedStatus = nil
            if Date().timeIntervalSince(saved.time) < 600 { hold(saved.status) }
        }
        guard state != .paired else { return }
        guard listener != nil else { return start() }
        Task { [relay] in await relay?.reconnect() }
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
            if state == .joined || state == .paired { linked = true }
            if state == .paired { paired() }
        case .ownerOnline(let online):
            ownerOnline = online
        case .peerInfo(let info):
            hostName = info.computerName
            macVersion = info.appVersion
        case .compatibility(let compatibility):
            if case .updateRequired(let reason) = compatibility {
                updateRequired = String(localized: "Update required: \(reason)")
            } else {
                updateRequired = nil
            }
        case .failed(let reason):
            failure = reason
        case .accepted:
            break // Delivered marks arrive with the outbox (#314, rc-ios).
        case .event(let event):
            receive(event)
        }
        releaseHeldIfSettled()
    }

    /// Off `.paired`: the flags are unknown, and nothing in flight will be answered.
    private func unlinked() {
        working = nil
        routing = nil
        controlling = []
        searchOffset = nil
        pageDeadline?.cancel()
        pageDeadline = nil
        requestedAfter = nil
        chunks = ChunkAssembler()
    }

    /// The relay never buffers Mac -> phone frames, so every `.paired` catches up and resends.
    private func paired() {
        // `PairingStore.markPaired` stamps the first join; mirror it rather than reread the Keychain.
        if pairedAt == nil { pairedAt = Date() }
        failure = nil
        updateRequired = nil
        catchingUp = true
        requestSync()
        // The relay dropped a page request that went out before the link fell: ask again.
        if let page, page.bubbles.isEmpty, page.error == nil { Task { await requestPage() } }
        let events = unreceipted
        Task { [relay] in
            for event in events { try? await relay?.send(event) }
        }
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

    /// The draft stays in the composer until the relay has taken the message.
    func send() async {
        let text = draft
        guard let relay, canSend else { return }
        sending = true
        defer { sending = false }
        let event = YorozuEvent(id: UUID().uuidString, threadId: "main", ts: Self.now, agentId: "device",
                                payload: .message(MessageData(role: .user, text: text)))
        unreceipted.append(event)
        // Before the await, so a stored copy arriving meanwhile is never overwritten by this one.
        merge(Bubble(id: event.id, user: true, ts: event.ts, text: text))
        do {
            try await relay.send(event)
        } catch {
            unreceipted.removeAll { $0.id == event.id }
            bubbles.removeAll { $0.id == event.id && $0.seq == nil }
            sendError = error.localizedDescription
            return
        }
        sendError = nil
        if draft == text { draft = "" }
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
        case .receipt(let receipt):
            unreceipted.removeAll { $0.id == receipt.eventId }
        case .admissionStatus(let status) where status.status == .rejected:
            unreceipted.removeAll { $0.id == status.eventId }
            if let index = bubbles.firstIndex(where: { $0.id == status.eventId }) {
                bubbles[index].failed = true
                bubbles[index].reason = status.reason
            }
        case .syncDelta(let delta):
            receive(delta)
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

    /// The upsert rule: a held record is replaced only by one with a higher `seq`; `worker_event` is insert-only.
    private func applyRecord(_ event: YorozuEvent) {
        switch event.payload {
        case .message(let message):
            let held = bubbles.first { $0.id == event.id }
            guard held?.seq == nil || (held?.seq ?? 0) < (message.seq ?? 0) else { return }
            merge(Bubble(record: event.id, ts: event.ts, message))
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
            if workerEvents[workerEvent.id] == nil { workerEvents[workerEvent.id] = workerEvent }
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
            amendments: Array(amendments.values), workerEvents: Array(workerEvents.values)))
    }

    /// The history window by the phone's clock and count: the newest 500 stored messages plus every
    /// one younger than 30 days, and the topics, tasks, amendments and worker events they reach, plus
    /// unsuppressed active or uncertain tasks (the Mac's work scope).
    private func trim() {
        let cutoff = Self.now - Self.windowDays * 86_400_000
        let stored = bubbles.filter { $0.seq != nil }
        let newest = Set(stored.suffix(Self.windowCount).map(\.id))
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
    /// The Mac key's first 8 bytes as hex, to compare with the Mac's screen.
    var fingerprint: String {
        (Data(base64URLEncoded: macPubkey) ?? Data()).prefix(8)
            .map { String(format: "%02x", $0) }.joined(separator: " ")
    }
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
