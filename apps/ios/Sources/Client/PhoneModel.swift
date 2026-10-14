import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import YorozuWire

/// The phone's half of docs/ios-relay-contract.md: the one pairing, the `RelayClient` it drives,
/// and the mirror of the Mac's history window (bubbles, topics, tasks, amendments, worker events,
/// read cursor), kept on disk in `HistoryStore` and caught up by change sequence. With a host that takes `history-v1`
/// (#405) the mirror is the whole history, backfilled page by page from the start and kept for offline reading and search.
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
        /// `threads-v1`: the thread it is in, which keeps it off the main timeline; nil there. Optional so an older cache loads.
        var threadId: String?
        /// `history-v1` (#405): the host sent only the head of the text; the whole is being fetched (`text_request`).
        var truncated: Bool?

        var files: [AttachmentInfo] { attachments ?? [] }

        init(id: String, user: Bool, ts: Int, text: String, failed: Bool = false,
             kind: String? = nil, topicId: String? = nil, taskId: String? = nil, replyTo: String? = nil,
             notice: NoticeData? = nil, seq: Int? = nil, readAt: Int? = nil, sentAt: Int? = nil,
             attachments: [AttachmentInfo] = [], threadId: String? = nil) {
            self.id = id
            self.threadId = threadId
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
                      readAt: m.readAt, sentAt: m.sentAt, attachments: m.attachmentInfos, threadId: m.threadId)
            truncated = m.truncated
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
        /// `main`, or the thread the page is from (`threads-v1`).
        var threadId = "main"
        var bubbles: [Bubble] = []
        var error: String?
    }

    /// The Main chat's composer, kept as its draft (#405).
    var draft = "" { didSet { saveMainDraft() } }
    /// Files staged in the composer (#316).
    var draftFiles: [StagedFile] = [] { didSet { saveMainDraft() } }
    /// Every unsent draft on this device, with its files (#405).
    let drafts = Drafts()
    @ObservationIgnored private var restoringDraft = false
    private func saveMainDraft() {
        guard !restoringDraft, ownPub != nil else { return }
        drafts.update(Drafts.chat(ThreadData.mainId), text: draft, files: draftFiles, replyTo: replyingTo)
    }
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
    private func rebuildTimeline() { timeline = bubbles.filter { !Self.jobOnlyKinds.contains($0.kind ?? "") && $0.threadId == nil } }
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

    /// The Mac negotiated `jobs-v1`; nil until it has said. Job input waits in the outbox unless true.
    private(set) var jobsSupported: Bool?
    /// The Mac's latest `job_list`, kept in the cache.
    private(set) var jobs: [JobListData.Job] = []
    /// When `jobs` arrived from the Mac; nil before any list.
    private(set) var jobsUpdated: Date?
    /// `job_control` events awaiting their answer: event id -> job id. Those jobs' actions stay disabled.
    private(set) var jobControls: [String: String] = [:]
    /// The latest refusal per job.
    private(set) var jobRefusals: [String: String] = [:]
    /// The cache was filled with `jobs-v1`, so it holds the job-only messages; without it a cursor skips them.
    private var cacheHasJobs = false
    /// Sub-chats that belong to jobs: reached through Jobs, not the topic list.
    var jobTopicIds: Set<String> { Set(jobs.compactMap(\.topicId)) }

    // Threads (`threads-v1`, owner 2026-10-13).
    /// Whether the host takes `threads-v1`; nil until known.
    private(set) var threadsSupported: Bool?
    /// The thread list loaded so far, newest activity first, and the cursor of its next page (Show more); the same for
    /// the archived list, which loads only while shown. Both come from the host, a page at a time, never from the cache.
    private(set) var threadList: [ThreadData] = []
    private(set) var threadsNext: String?
    private(set) var archivedThreads: [ThreadData] = []
    private(set) var archivedNext: String?
    /// The last `threads_page` error, until the next page arrives.
    private(set) var threadsError: String?
    /// `thread_control` in flight (request id → thread id) and the last refusal per thread.
    private(set) var threadControls: [String: String] = [:]
    private(set) var threadRefusals: [String: String] = [:]
    /// Read cursors of the threads other than main, in memory only.
    private(set) var threadReads: [String: ReadStateData] = [:]
    private var threadsRequests: [String: (archived: Bool, append: Bool)] = [:]
    private var threadsRefresh: Task<Void, Never>?
    private var cacheHasThreads = false

    // MARK: History (#405)

    /// The whole history on disk, for this pairing; nil without a pairing.
    @ObservationIgnored private var history: HistoryStore?
    /// Records changed or removed since the last write, written in one batch at most once a second.
    @ObservationIgnored private var dirty: Set<HistoryStore.Key> = []
    @ObservationIgnored private var removed: Set<HistoryStore.Key> = []
    /// The host serves the whole history (`history-v1`); nil until it has said.
    private(set) var historySupported: Bool?
    /// Every record the host has is here, text included: the backfill reached the host's latest sequence and no long text
    /// is still being fetched. False on a first sync, after an upgrade from the window cache and while a backfill resumes.
    private(set) var historySynced = false
    /// A reset from a cursor the host no longer knows (another database): incoming records replace held ones whatever
    /// their `seq`, until that catch-up ends. Nothing held is dropped.
    @ObservationIgnored private var replacing = false
    /// Deleted threads (their tombstones): nothing of them is kept or shown again, whatever a later page carries.
    private(set) var deletedThreads: Set<String> = []
    /// Long text fields the host cut to send (`truncated`), fetched whole one slice at a time.
    private struct TextNeed: Hashable { var kind: String; var id: String; var field: String; var seq: Int }
    @ObservationIgnored private var textNeeds: [TextNeed] = []
    @ObservationIgnored private var textFetch: (need: TextNeed, bytes: Data)?
    @ObservationIgnored private var textDeadline: Task<Void, Never>?
    /// Why the last long-text fetch failed; it is retried. Cleared by the next whole text.
    private(set) var textError: String?
    /// Tasks of deleted threads (from their tombstones): their steps and changes are never kept again.
    @ObservationIgnored private var deletedTasks: Set<String> = []
    /// Messages the host deleted one by one (`deleted` records): never kept again.
    @ObservationIgnored private var deletedMessages: Set<String> = []
    /// The host's Main chat setting (`host-settings-v1`), the last value it confirmed, kept for offline use; nil until known.
    private(set) var mainChat: Bool?
    private(set) var hostSettingsSupported: Bool?
    /// The host's last settings: the Main chat's name, archive and deletion time with the switch (#405).
    private(set) var hostSettings: HostSettingsData?
    /// The newest message this device marked read per chat, so its row's unread dot goes before the host's row says so.
    private(set) var sentReads: [String: String] = [:]
    /// The Main chat's row from the host while it is on (`ThreadsPageData.main`), cached.
    private(set) var mainRow: ThreadData?
    /// Thread pages being gathered for a refresh, so the shown list is replaced only when its last page is in.
    @ObservationIgnored private var gathering: [Bool: [ThreadData]] = [:]
    func canControlThread(_ id: String) -> Bool { state == .paired && threadsSupported == true && !threadControls.values.contains(id) }
    /// The bubbles of one thread: typed or answered in it, or filed in its topic (a secretary-started thread), oldest first.
    func bubbles(inThread id: String) -> [Bubble] { bubbles.filter { $0.threadId == id || $0.topicId == id } }
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
        // Written before the identity changes, so a crash between the two still finds the kept data (Repair only):
        // the next launch adopts what the previous identity left, and only that.
        if pending.repair, let ownPub {
            UserDefaults.standard.set(["from": ownPub, "to": stored.identity.sessionPublicKey.base64URLEncodedString()], forKey: Self.repairKey)
        }
        do { try PairingStore.save(stored) } catch {
            failure = error.localizedDescription
            return
        }
        // Repair keeps the host (#405): its history, downloads, drafts and unsent messages stay with the new identity. Any
        // other host starts from nothing, so nothing of one host's chats reaches another.
        disconnect(keep: pending.repair)
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
        #if os(iOS)
        PreviewKeychain.clear()
        #endif
        disconnect()
    }

    private func sendDeviceRemove() async {
        guard state == .paired, let relay, let ownPub else { return }
        try? await relay.send(YorozuEvent(id: UUID().uuidString, threadId: "main", ts: Self.now, agentId: "device",
                                          payload: .deviceRemove(DeviceRemoveData(pub: ownPub))))
    }

    /// A Repair of the same host in progress: the identity before it and after it (`confirm`).
    private static let repairKey = "repairAdoptV1"

    private func connect(_ stored: PairingStore.Stored) {
        let identity = stored.identity.sessionPublicKey
        let pushKey = "\(Self.pushKey).\(identity.base64URLEncodedString())"
        // The notification extension's key for this Mac's sealed previews, written on every connect so it follows the pairing.
        #if os(iOS)
        if let mac = Data(base64URLEncoded: stored.pairing.macPubkey),
           let key = try? PushPreview.key(myPriv: stored.identity.sessionPrivateKey, theirPub: mac) { PreviewKeychain.save(key) }
        #endif
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
        // A Repair's kept data becomes this identity's; the marker goes once all of it is written as this owner's.
        let repair = UserDefaults.standard.dictionary(forKey: Self.repairKey) as? [String: String]
        let adoptFrom = ownPub != nil && repair?["to"] == ownPub ? repair?["from"] : nil
        var adopted = true
        if let ownPub {
            openHistory(owner: ownPub, adoptFrom: adoptFrom)
            adopted = drafts.load(owner: ownPub, adoptFrom: adoptFrom)
            let main = drafts.draft(Drafts.chat(ThreadData.mainId))
            restoringDraft = true
            draft = main.text; draftFiles = main.files; replyingTo = main.replyTo
            restoringDraft = false
        }
        if let ownPub, let saved = Outbox.file.load(Outbox.self), saved.owner == ownPub || (adoptFrom != nil && saved.owner == adoptFrom) {
            outbox = saved.items
            marks = saved.marks
            reminderAt = saved.reminderAt
            reminderCovered = saved.reminderCovered
            // The cache keeps stored messages only: draw the rest from the outbox.
            for item in outbox where !item.stored {
                // Files still in the outbox show from there.
                for (index, info) in (item.files ?? []).enumerated() { files.register(UploadStore.url(item.id, index), for: info) }
                if case .message(let message) = item.event.payload, !bubbles.contains(where: { $0.id == item.id }) {
                    merge(Bubble(id: item.id, user: true, ts: item.event.ts, text: message.text, kind: message.jobId.map { _ in "job_input" },
                                 topicId: item.topicId, replyTo: message.replyTo, attachments: item.files ?? [], threadId: message.threadId))
                }
            }
            expireOverdue()
            consumed = saved.consumed ?? [:]
            drafts.dropSent(outbox.compactMap { item in item.draftKey.flatMap { key in item.draftStamp.map { (key, $0) } } } + consumed.map { ($0.key, $0.value) })
            let main = drafts.draft(Drafts.chat(ThreadData.mainId))
            restoringDraft = true
            draft = main.text; draftFiles = main.files; replyingTo = main.replyTo
            restoringDraft = false
            // At once, and kept: a message waiting since before the update gets its reminder even if nothing changes (#405).
            saveOutbox()
            if adoptFrom != nil {
                adopted = adopted && Outbox.file.saveNow(Outbox(owner: ownPub, items: outbox, marks: marks, reminderAt: reminderAt,
                                                                reminderCovered: reminderCovered, consumed: consumed.isEmpty ? nil : consumed))
            }
        }
        if adoptFrom != nil, adopted, history?.ownerWritten == true { UserDefaults.standard.removeObject(forKey: Self.repairKey) }
        else if repair != nil, adoptFrom == nil { UserDefaults.standard.removeObject(forKey: Self.repairKey) } // another identity: never adopted
    }

    /// Forgets the pairing's link and its whole mirror, cache file included.
    /// `keep`: a Repair of the same host, whose data on this device stays for the new identity.
    private func disconnect(keep: Bool = false) {
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
        if !keep { outbox.forEach { LocalNotices.cancelExpiry($0.id) } }
        #if os(iOS)
        PushNotices.update(badge: 0, read: nil)
        #endif
        localRead = nil
        clearedTo = nil
        outbox = []
        marks = [:]
        if !keep {
            Outbox.file.wipe()
            UploadStore.wipe()
            files.wipe()
        }
        uploading = []
        uploadProgress = [:]
        uploadOffsets = [:]
        attachmentsSupported = nil
        jobsSupported = nil
        jobs = []
        jobsUpdated = nil
        jobRefusals = [:]
        cacheHasJobs = false
        restoringDraft = true
        draftFiles = []
        draft = ""
        replyingTo = nil
        restoringDraft = false
        if keep { drafts.saveNow() } else { drafts.wipe() }
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
        dirty = []
        removed = []
        metaDirty = false
        // A write still in flight belongs to this history: its late answer is ignored, and the next pairing starts clean.
        writing = false
        afterCommit = []
        historyWriteFailed = false
        deletedThreads = []
        deletedTasks = []
        deletedMessages = []
        sentReads = [:]
        reminderAt = nil
        reminderCovered = nil
        if !keep {
            LocalNotices.cancelReminder(delivered: true)
            history?.wipe()
        }
        history?.drain()
        history = nil
        MirrorCache.shared.wipe()
        historySupported = nil
        historySynced = false
        hostSettingsSupported = nil
        mainChat = nil
        hostSettings = nil
        mainRow = nil
        threadList = []
        archivedThreads = []
        threadsNext = nil
        archivedNext = nil
        gathering = [:]
        textNeeds = []
        textFetch = nil
    }

    // MARK: Connection

    /// Dials unless already dialling; `RelayClient` redials by itself after a drop until `suspend()`.
    func start() {
        // Dials once the history is loaded (`adopt`).
        if historyLoading { startWanted = true; return }
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
        drafts.save()
        flush()
        inBackground = true
        guard sendingCount > 0 else { return waking ? () : suspend() }
        backgroundTime = BackgroundTask("Yorozu outbox") { [weak self] in self?.backgroundExpired() }
        flushOutbox(all: state == .paired)
    }

    /// Background time ran out with messages still Sending: say so, and hang up.
    private func backgroundExpired() {
        backgroundTime = nil
        // The unsent reminder, scheduled with the system, covers what is still waiting (#405).
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
        #if os(iOS)
        PushNotices.removeBackOnline()
        #endif
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
        if Self.inBackground {
            if backgroundTime != nil { finishBackgroundIfDone() } else if dialled || inBackground { suspend() }
            await closing?.value
        }
        return cursor != before
    }

    func open(pushEvent ref: String?) { pushOpen = PushOpen(ref: ref) }

    /// The message a push's `event` ref names, on the main timeline or in a thread (its bubble's `threadId`).
    func messageId(ref: String) -> String? { bubbles.last { YorozuCrypto.threadRef($0.id) == ref }?.id }

    /// The badge is Yorozu's messages after the later of this phone's read and the Mac's cursor, or all of them when
    /// neither is in the timeline. When that read moves, the delivered pushes for messages at or before it go.
    private func updateBadge() {
        let index = [localRead, readCursor?.messageId].compactMap { id in timeline.firstIndex { $0.id == id } }.max()
        let id = index.map { timeline[$0].id }
        let read = index.flatMap { i in id == clearedTo ? nil : Set(timeline[...i].map { YorozuCrypto.threadRef($0.id) }) }
        clearedTo = id
        #if os(iOS)
        PushNotices.update(badge: timeline[(index.map { $0 + 1 } ?? 0)...].filter { !$0.user }.count, read: read)
        #endif
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
                // The same for thread messages (`threads-v1`), which a host strips for a phone without it.
                threadsSupported = capabilities.contains(ThreadData.capability)
                if threadsSupported == true, !cacheHasThreads {
                    cacheHasThreads = true
                    cursor = nil
                }
                historySupported = capabilities.contains(ThreadData.historyCapability)
                hostSettingsSupported = capabilities.contains(HostSettingsData.capability)
                saveMeta()
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
        // A slice in flight is asked for again from the start on the next `.paired`; the need itself stays.
        textFetch = nil
        textDeadline?.cancel()
        working = nil
        routing = nil
        readiness = nil
        controlling = []
        jobControls = [:]
        threadControls = [:]
        threadsRequests = [:]
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
        requestText()
        Task {
            await loadThreads()
            await loadThreads(archived: true)
        }
    }

    /// Asks for the changes after the cursor, and again after 15 s with neither a reply page nor a chunk.
    private func requestSync() {
        requestedAfter = cursor ?? 0
        let event = YorozuEvent(id: UUID().uuidString, threadId: "main", ts: Self.now, agentId: "device",
                                payload: .syncRequest(SyncRequestData(threadId: "main", afterSeq: cursor, full: historySupported == true ? true : nil)))
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
    /// The app is in the background: on a Mac, which keeps running, never.
    private static var inBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    func send() {
        drafts.saveNow()
        guard send(text: draft, files: draftFiles, replyTo: replyingTo, draftKey: Drafts.chat(ThreadData.mainId)) else { return }
        restoringDraft = true
        defer { restoringDraft = false }
        draft = ""
        draftFiles = []
        replyingTo = nil
    }

    /// One message through the outbox; false when nothing went (not sendable, empty, or files not kept).
    @discardableResult
    /// `thread` (`threads-v1`): the thread it is typed in; `newThread`: New chat's first message, which creates that thread
    /// on the host with this id, so it works offline through the outbox like any message.
    /// `draftKey`: the draft it is sent from, consumed in step with the outbox (#405).
    func send(text: String, files picked: [StagedFile], replyTo: String? = nil, thread: String? = nil, newThread: Bool = false, draftKey: String? = nil,
              id chosen: String? = nil) -> Bool {
        guard canSend, thread == nil || threadsSupported == true, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !picked.isEmpty else { return false }
        let ts = Self.now
        let id = chosen ?? UUID().uuidString
        var infos: [AttachmentInfo] = []
        if !picked.isEmpty {
            do {
                infos = try UploadStore.store(picked, for: id)
            } catch {
                attachFailure = String(localized: "Couldn’t keep the files for sending. Try again.")
                return false
            }
            for (index, info) in infos.enumerated() { files.register(UploadStore.url(id, index), for: info) }
            uploadOffsets[id] = Array(repeating: 0, count: infos.count)
            UploadStore.setOffsets(id, uploadOffsets[id] ?? [])
        }
        let event = YorozuEvent(id: id, threadId: thread ?? "main", ts: ts, agentId: "device",
                                payload: .message(MessageData(role: .user, text: text, admissionDeadline: ts + Outbox.lifetime, replyTo: replyTo,
                                                              threadId: thread, newThread: newThread ? true : nil)))
        guard enqueue(Outbox.Item(event: event, sentAt: ts, files: infos.isEmpty ? nil : infos, topicId: thread,
                                  draftKey: draftKey, draftStamp: draftKey.map { drafts.draft($0).updated }),
                      Bubble(id: id, user: true, ts: ts, text: text, topicId: thread, replyTo: replyTo, attachments: infos, threadId: thread)) else {
            UploadStore.remove(id)
            uploadOffsets[id] = nil
            attachFailure = String(localized: "Couldn't save the message on this device, so it wasn't sent. Your draft is kept. Free up some space and try again.")
            return false
        }
        // Durably queued: the draft goes (on disk too), then its own copies.
        if let draftKey { consumeDraft(draftKey, stamp: drafts.draft(draftKey).updated) }
        picked.forEach { $0.discard() }
        return true
    }

    /// Sends what the share extension left (`ShareInbox`), oldest first, each as its own message; a share stays until it
    /// can go (paired, host not blocked). Called at launch and on each return to the foreground.
    func sendShares() {
        #if os(iOS)
        guard canSend else { return }
        for (share, folder) in ShareInbox.pending() {
            var files: [StagedFile] = []
            if let name = share.fileName {
                // `stage` moves its source: give it a copy, so a failed send leaves the share whole.
                let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + name)
                guard (try? FileManager.default.copyItem(at: folder.appending(path: name), to: copy)) != nil,
                      let staged = try? StagedFile.stage(copy, name: name) else { try? FileManager.default.removeItem(at: folder); continue }
                files = [staged]
            }
            if send(text: share.text, files: files) { try? FileManager.default.removeItem(at: folder) }
            files.forEach { $0.discard() }
        }
        #endif
    }

    /// A job's own input (#319): through the outbox like any message, filed in the job's sub-chat. Text only. Queued before the
    /// handshake too (a job page from the cached list); the flush holds it until the Mac has said it takes `jobs-v1`.
    @discardableResult
    func send(_ text: String, toJob job: String, topic: String, draftKey: String? = nil) -> Bool {
        guard canSend, jobsSupported != false, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let ts = Self.now
        let event = YorozuEvent(id: UUID().uuidString, threadId: "main", ts: ts, agentId: "device",
                                payload: .message(MessageData(role: .user, text: text, admissionDeadline: ts + Outbox.lifetime, jobId: job)))
        let stamp = draftKey.map { drafts.draft($0).updated }
        guard enqueue(Outbox.Item(event: event, sentAt: ts, topicId: topic, draftKey: draftKey, draftStamp: stamp),
                      Bubble(id: event.id, user: true, ts: ts, text: text, kind: "job_input", topicId: topic)) else { return false }
        if let draftKey, let stamp { consumeDraft(draftKey, stamp: stamp) }
        return true
    }

    /// A message with this id waits in the outbox.
    func hasQueued(_ id: String) -> Bool { outbox.contains { $0.id == id } }

    /// The sent draft leaves the disk; until that write succeeds a marker beside the outbox keeps it from coming back.
    private func consumeDraft(_ key: String, stamp: Int) {
        if drafts.consume(key) { return }
        consumed[key] = max(consumed[key] ?? 0, stamp)
        saveOutbox()
    }
    @ObservationIgnored private var consumed: [String: Int] = [:]

    /// Retries the draft removals a failed write left, with the outbox's own write.
    private func settleConsumed() {
        guard !consumed.isEmpty else { return }
        drafts.dropSent(consumed.map { ($0.key, $0.value) })
        if drafts.saveNow() { consumed = consumed.filter { key, stamp in drafts.all[key].map { $0.updated <= stamp } == true } }
    }

    /// Into the outbox, written to disk before Send counts as done (#405): false, with nothing queued, when it was not.
    @discardableResult
    private func enqueue(_ item: Outbox.Item, _ bubble: Bubble) -> Bool {
        outbox.append(item)
        setMark(item.id, .sending)
        guard let ownPub, Outbox.file.saveNow(Outbox(owner: ownPub, items: outbox, marks: marks, reminderAt: reminderAt, reminderCovered: reminderCovered, consumed: consumed.isEmpty ? nil : consumed)) else {
            outbox.removeAll { $0.id == item.id }
            marks[item.id] = nil
            LocalNotices.cancelExpiry(item.id)
            return false
        }
        merge(bubble)
        saveOutbox()
        queued()
        return true
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
            draftFiles.append(try StagedFile.textFile(draft))
        } catch {
            attachFailure = String(localized: "Couldn’t keep the files for sending. Try again.")
            return
        }
        draft = ""
        send()
    }

    /// The main-timeline message the next `send()` replies to (`MessageData.replyTo`); the host files the reply with it.
    var replyingTo: String? { didSet { saveMainDraft() } }

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
        if state != .joined && state != .paired {
            // Once allowed, the reminder is scheduled again (one asked before the answer may not have been kept). iOS
            // prompts only once; a denial is respected, never asked again.
            Task { [weak self] in
                guard await LocalNotices.askPermission() else { return }
                self?.reminderAt = nil
                self?.reminderCount = 0
                self?.saveOutbox()
            }
        }
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
            // Job input waits until the Mac has said it takes `jobs-v1`: a job page from the cached list can queue it sooner.
            if case .message(let message) = item.event.payload, message.jobId != nil, jobsSupported != true { continue }
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
                                                          text: message.text, admissionDeadline: item.deadline, files: files,
                                                          newThread: message.newThread))
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
        // Held by the relay is not on the host: the reminder and the expiry notice stay (#405).
        if buffered { LocalNotices.requestPermission() }
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
        // Past its deadline the host refuses it anyway (host check 5), so a message the relay holds expires here too and is
        // never sent late; Resend starts a new 24 hours.
        for item in outbox where (marks[item.id] == .sending || marks[item.id] == .delivered) && !item.stored && now > item.deadline {
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
        case .sending:
            // A send or a resend: its own 24 hours from now.
            if let item = outbox.first(where: { $0.id == id }), !item.stored { LocalNotices.scheduleExpiry(id, at: item.deadline) }
        case .read:
            LocalNotices.cancelExpiry(id)
        case .notDelivered:
            LocalNotices.cancelExpiry(id)
            AccessibilityNotification.Announcement(String(localized: "Message not delivered")).post()
        }
    }

    private func saveOutbox() {
        guard let ownPub else { return }
        reconcileReminder()
        settleConsumed()
        Outbox.file.save(Outbox(owner: ownPub, items: outbox, marks: marks, reminderAt: reminderAt, reminderCovered: reminderCovered,
                                consumed: consumed.isEmpty ? nil : consumed))
    }

    /// The unsent reminder's schedule, kept with the outbox so a relaunch does not reset it.
    @ObservationIgnored private var reminderAt: Int?
    @ObservationIgnored private var reminderCovered: Int?

    /// The unsent reminder from the outbox's durable state (#405), on every change to it, at launch and on a timing change.
    /// A message counts until the host has it (its `receipt` or stored copy): the relay's `accepted` is not the host, and
    /// whether the assistant has read it does not matter. One notification at the earliest message's age past Send,
    /// counting every message due by then; Off, or none left, cancels it.
    func reconcileReminder() {
        let now = Self.now, delay = LocalNotices.reminderMinutes * 60_000
        // A reminder whose time passed has fired: it covered every message sent by then.
        if let at = reminderAt, at <= now { reminderCovered = max(reminderCovered ?? 0, at); reminderAt = nil }
        let waiting = outbox.filter { !$0.stored && marks[$0.id] != .notDelivered && marks[$0.id] != .read }
        guard delay > 0, !waiting.isEmpty else {
            if scheduling != nil { reminderGeneration += 1; scheduling = nil }
            if reminderAt != nil || reminderCovered != nil { LocalNotices.cancelReminder(delivered: waiting.isEmpty) }
            reminderAt = nil
            if waiting.isEmpty { reminderCovered = nil }
            return
        }
        // Grouped: one notice when the oldest uncovered message reaches the reminder age, counting every message still
        // waiting then (sent by then), so a later one in the same group is covered even if the app stays suspended. A
        // message sent after that gets the next notice.
        let uncovered = waiting.filter { $0.sentAt > (reminderCovered ?? 0) }
        guard let oldest = uncovered.map(\.sentAt).min() else {
            reminderGeneration += 1; scheduling = nil
            LocalNotices.cancelReminder(delivered: false); reminderAt = nil; return
        }
        let at = max(oldest + delay, now + 1000)
        let count = waiting.filter { $0.sentAt <= at }.count
        guard at != reminderAt || count != reminderCount, scheduling?.at != at || scheduling?.count != count else { return }
        reminderGeneration += 1
        let generation = reminderGeneration
        scheduling = (at, count)
        LocalNotices.scheduleReminder(at: at, count: count) { ok in
            Task { @MainActor [weak self] in
                // A newer schedule, a cancellation or a receipt since: this answer is stale.
                guard let self, self.reminderGeneration == generation else { return }
                self.scheduling = nil
                // Recorded (and written with the outbox) only once the system took it; a failure is tried again.
                guard ok else { return }
                self.reminderAt = at
                self.reminderCount = count
                self.saveOutbox()
            }
        }
    }
    /// A schedule handed to the system and not yet confirmed; bumped generations make late answers stale.
    @ObservationIgnored private var scheduling: (at: Int, count: Int)?
    @ObservationIgnored private var reminderGeneration = 0
    @ObservationIgnored private var reminderCount = 0

    /// Settings › Unsent reminder.
    func setReminder(minutes: Int) {
        LocalNotices.reminderMinutes = minutes
        reminderGeneration += 1
        scheduling = nil
        reminderAt = nil
        reminderCount = 0
        LocalNotices.cancelReminder(delivered: false)
        saveOutbox()
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
    func loadPage(around messageId: String, thread: String = "main") async -> Bool {
        guard state == .paired else { return false }
        page = PageReply(requestId: UUID().uuidString, messageId: messageId, threadId: thread)
        return await requestPage()
    }

    private func requestPage() async -> Bool {
        guard let held = page else { return false }
        let ok = await sendNow(.pageRequest(PageRequestData(requestId: held.requestId, threadId: held.threadId, messageId: held.messageId)))
        if !ok, page?.requestId == held.requestId { page = nil }
        return ok
    }

    /// Moves the Mac's read cursor to the newest message seen, of the main timeline or of one thread (`threads-v1`).
    /// Only while `.paired`; not queued.
    func markRead(_ messageId: String, thread: String = "main") async {
        guard state == .paired else { return }
        if thread == "main" { localRead = messageId; updateBadge() }
        sentReads[thread] = messageId
        _ = await sendNow(.readState(ReadStateData(threadId: thread, messageId: messageId)))
    }

    // MARK: Threads (`threads-v1`, owner 2026-10-13)

    /// The thread list's first page again, as many rows as are loaded (30 to 200), or with `more` the next page (Show
    /// more). `archived` loads the archived list instead. Needs `.paired` and a host that takes `threads-v1`.
    @discardableResult
    func loadThreads(archived: Bool = false, more: Bool = false) async -> Bool {
        guard state == .paired, threadsSupported == true else { return false }
        let after = more ? (archived ? archivedNext : threadsNext) : nil
        if more, after == nil { return false }
        let loaded = archived ? archivedThreads.count : threadList.count
        let id = UUID().uuidString
        threadsRequests[id] = (archived, more)
        _ = loaded
        let ok = await sendNow(.threadsRequest(ThreadsRequestData(requestId: id, archived: archived ? true : nil, after: after, limit: 200)))
        if !ok { threadsRequests[id] = nil }
        return ok
    }

    /// Rename, archive, unarchive or delete one thread: one at a time per thread, only while `.paired`, never queued.
    @discardableResult
    func control(thread id: String, _ action: ThreadControlData.Action, name: String? = nil) async -> Bool {
        guard canControlThread(id) else { return false }
        let requestId = UUID().uuidString
        threadControls[requestId] = id
        threadRefusals[id] = nil
        let ok = await sendNow(.threadControl(ThreadControlData(requestId: requestId, threadId: id, action: action, name: name)))
        if !ok { threadControls[requestId] = nil }
        return ok
    }

    /// Every page is gathered (#405): the whole list is cached for offline use and replaces the shown one only once its last
    /// page is in, so a refresh never empties it and an error keeps the list held.
    private func receive(_ page: ThreadsPageData) {
        guard let request = threadsRequests.removeValue(forKey: page.requestId) else { return }
        threadsError = page.error
        guard page.error == nil else { gathering[request.archived] = nil; return }
        if !request.append, !request.archived { mainRow = mainChat == true ? page.main : nil }
        let held = request.append ? gathering[request.archived] ?? [] : []
        let rows = held + page.threads.filter { row in !held.contains { $0.id == row.id } }
        if let next = page.next {
            gathering[request.archived] = rows
            if request.archived { archivedNext = next } else { threadsNext = next }
            Task { await loadThreads(archived: request.archived, more: true) }
            return
        }
        gathering[request.archived] = nil
        if request.archived { archivedThreads = rows; archivedNext = nil } else { threadList = rows; threadsNext = nil }
        saveMeta()
    }

    /// The Main chat's own messages up to `at` were deleted on the host (#405): the same ones go here, from search too, and
    /// never come back from a later page. Messages a task or a change refers to stay, as on the host.
    private func clearMain(upTo at: Int) {
        // As on the host (`Store.clearMain`): every Main-timeline message up to then, and the work they started.
        let requests = Set(bubbles.filter { $0.seq != nil && Self.onMain($0) && $0.ts <= at }.map(\.id))
        guard !requests.isEmpty else { return }
        let goneTasks = Set(tasks.values.filter { requests.contains($0.messageId) }.map(\.id))
        // With them, whenever they were written: what that work posted and the replies to those requests (as on the host).
        let gone = requests.union(bubbles.filter { b in b.taskId.map(goneTasks.contains) == true || (!b.user && b.replyTo.map(requests.contains) == true) }.map(\.id))
        deletedTasks.formUnion(goneTasks)
        gone.forEach { drop("message", $0) }
        goneTasks.forEach { tasks[$0] = nil; drop("task", $0) }
        for a in amendments.values where goneTasks.contains(a.taskId) || gone.contains(a.messageId) { amendments[a.id] = nil; drop("amendment", a.id) }
        for w in workerEvents.values where goneTasks.contains(w.taskId) { workerEvents[w.id] = nil; drop("event", w.id) }
        bubbles.removeAll { gone.contains($0.id) }
        readCursor = nil
        drop("read", "main")
    }

    /// A Main-timeline message (not in a thread, not job-only).
    nonisolated static func onMain(_ b: Bubble) -> Bool { b.threadId == nil && !jobOnlyKinds.contains(b.kind ?? "") }

    /// Turns the host's Main chat on or off (`host-settings-v1`): only while `.paired`; the host's answer is what shows.
    @discardableResult
    func setMainChat(_ on: Bool) -> Bool {
        guard state == .paired, hostSettingsSupported == true else { return false }
        Task { _ = await sendNow(.hostSettings(HostSettingsData(mainChat: on))) }
        return true
    }

    /// A hit of the local search: a message or a worker step, where it is, and whether its chat is archived.
    struct LocalHit: Identifiable, Equatable {
        var id: String
        var messageId: String?
        var eventId: String?
        var taskId: String?
        /// The thread it is in, nil for the main timeline.
        var threadId: String?
        var topicId: String?
        var snippet: String
        var ts: Int
        var archived: Bool
    }

    /// Search over the history on this device, offline (#405): every chat, archived ones included and marked.
    func searchLocal(_ query: String, limit: Int = 300) -> [LocalHit] {
        flush()
        history?.drain()
        let archived = Set(archivedThreads.map(\.id)).union(topics.values.filter { $0.archivedAt != nil }.map(\.id))
        // From the store's own rows, not what is in memory: a hit shows while the history is still loading (#405).
        return (history?.search(query, limit: limit) ?? []).compactMap { hit in
            guard ![hit.thread, hit.topic].contains(where: { $0.map(deletedThreads.contains) == true }) else { return nil }
            if hit.kind == "message" {
                let place = hit.thread ?? hit.topic
                return LocalHit(id: hit.id, messageId: hit.id, threadId: hit.thread, topicId: hit.topic, snippet: hit.snippet, ts: hit.ts,
                                archived: place.map(archived.contains) == true)
            }
            let task = workerEvents[hit.id].flatMap { tasks[$0.taskId] }
            guard let topic = task?.topicId ?? hit.topic, !deletedThreads.contains(topic) else { return nil }
            return LocalHit(id: hit.id, eventId: hit.id, taskId: task?.id, topicId: topic, snippet: hit.snippet, ts: hit.ts,
                            archived: archived.contains(topic))
        }
    }

    private func receive(_ result: ThreadControlResultData) {
        guard let thread = threadControls.removeValue(forKey: result.requestId) else { return }
        guard result.accepted else { threadRefusals[thread] = result.reason; return }
        threadList.removeAll { $0.id == thread }
        archivedThreads.removeAll { $0.id == thread }
        Task {
            await loadThreads()
            await loadThreads(archived: true)
        }
    }

    /// Records changed: the loaded lists again, at most once a second.
    private func refreshThreads() {
        guard threadsSupported == true, threadsRefresh == nil else { return }
        threadsRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.threadsRefresh = nil
            await self.loadThreads()
            await self.loadThreads(archived: true)
        }
    }

    /// A deleted thread (its tombstone record): everything of it goes from the mirror and the lists.
    private func purge(thread id: String) {
        deletedThreads.insert(id)
        let taskIds = Set(tasks.values.filter { $0.topicId == id }.map(\.id))
        deletedTasks.formUnion(taskIds)
        // Off the disk and out of local search as well (#405); the tombstone stays, so a later page cannot bring them back.
        for b in bubbles where b.threadId == id || b.topicId == id || b.taskId.map(taskIds.contains) == true { drop("message", b.id) }
        taskIds.forEach { drop("task", $0) }
        amendments.values.filter { taskIds.contains($0.taskId) }.forEach { drop("amendment", $0.id) }
        workerEvents.values.filter { taskIds.contains($0.taskId) }.forEach { drop("event", $0.id) }
        drop("read", id)
        textNeeds.removeAll { need in need.kind == "message" ? !bubbles.contains { $0.id == need.id && $0.threadId != id && $0.topicId != id } : taskIds.contains(need.id) }
        bubbles.removeAll { $0.threadId == id || $0.topicId == id || $0.taskId.map(taskIds.contains) == true }
        tasks = tasks.filter { !taskIds.contains($0.key) }
        amendments = amendments.filter { !taskIds.contains($0.value.taskId) }
        workerEvents = workerEvents.filter { !taskIds.contains($0.value.taskId) }
        topics[id] = nil
        threadReads[id] = nil
        threadList.removeAll { $0.id == id }
        archivedThreads.removeAll { $0.id == id }
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
            jobsUpdated = Date()
            scheduleSave()
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
        case .threadsPage(let page):
            receive(page)
        case .threadControlResult(let result):
            receive(result)
        case .textSlice(let slice):
            receive(slice)
        case .hostSettings(let settings):
            if hostSettings != settings {
                let refresh = mainChat != settings.mainChat
                mainChat = settings.mainChat
                hostSettings = settings
                if !settings.mainChat { mainRow = nil }
                if let at = settings.mainClearedAt { clearMain(upTo: at) }
                saveMeta()
                if refresh { refreshThreads() }
            }
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
        let requestedAfterReply = requestedAfter
        if reply {
            // An error page keeps the cursor; the deadline asks again.
            guard delta.error == nil else { return }
            pageDeadline?.cancel()
            pageDeadline = nil
            requestedAfter = nil
            // A reset never drops the history held (#405): from cursor 0 the pages merge by the upsert rule; from a cursor the
            // host no longer knows (another database) they replace what is held until the catch-up ends.
            if delta.reset == true {
                if historySupported != true { clearMirror(keepPending: true) }
                else if (requestedAfterReply ?? 0) > 0 { replacing = true }
                historySynced = false
            }
            delta.events.forEach(applyRecord)
            if let latest = delta.latestSeq { cursor = latest }
            if delta.more == true { requestSync() } else {
                catchingUp = false
                replacing = false
                if historySupported == true {
                    collectOrphans()
                    historySynced = textNeeds.isEmpty && textFetch == nil && !holdsCutText
                }
            }
            saveMeta()
        } else {
            delta.events.forEach(applyRecord)
            if !delta.events.isEmpty { refreshThreads() }
            if !catchingUp, let latest = delta.latestSeq {
                if (delta.afterSeq ?? 0) <= (cursor ?? 0) {
                    cursor = max(cursor ?? 0, latest)
                    saveMeta()
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
    /// images arrive later, re-stamped), or by any while `replacing`. Nothing of a deleted thread is kept again.
    private func applyRecord(_ event: YorozuEvent) {
        func newer(_ held: Int?, _ incoming: Int?) -> Bool { replacing || held == nil || (held ?? 0) < (incoming ?? 0) }
        switch event.payload {
        case .message(let message):
            if [message.threadId, message.topicId].contains(where: { $0.map(deletedThreads.contains) == true }) || message.taskId.map(deletedTasks.contains) == true
                || deletedMessages.contains(event.id) { return }
            // The Main chat's deleted history never comes back from an older page.
            if let cleared = hostSettings?.mainClearedAt, message.threadId == nil, event.ts <= cleared, !Self.jobOnlyKinds.contains(message.kind ?? "") { return }
            let held = bubbles.first { $0.id == event.id }
            guard held?.seq == nil || newer(held?.seq, message.seq) else { return }
            merge(Bubble(record: event.id, ts: event.ts, message))
            if message.truncated == true, let seq = message.seq { needText(TextNeed(kind: "message", id: event.id, field: "text", seq: seq)) }
            if message.role == .user, message.seq != nil { stored(event.id, read: message.readAt != nil) }
        case .topic(let topic) where topic.deleted == true:
            purge(thread: topic.id)
            topics[topic.id] = topic
            touch("topic", topic.id)
        case .topic(let topic):
            guard !deletedThreads.contains(topic.id), newer(topics[topic.id]?.seq, topic.seq) else { return }
            topics[topic.id] = topic
            touch("topic", topic.id)
        case .task(let task):
            guard !deletedThreads.contains(task.topicId), !deletedTasks.contains(task.id), newer(tasks[task.id]?.seq, task.seq) else { return }
            tasks[task.id] = task
            controlling.remove(task.id)
            // The result answered the record this replaces.
            controlResults[task.id] = nil
            touch("task", task.id)
            for field in task.truncated ?? [] { needText(TextNeed(kind: "task", id: task.id, field: field, seq: task.seq)) }
        case .amendment(let amendment):
            guard !deletedTasks.contains(amendment.taskId), newer(amendments[amendment.id]?.seq, amendment.seq) else { return }
            amendments[amendment.id] = amendment
            touch("amendment", amendment.id)
            for field in amendment.truncated ?? [] { needText(TextNeed(kind: "amendment", id: amendment.id, field: field, seq: amendment.seq)) }
        case .workerEvent(let workerEvent):
            guard !deletedTasks.contains(workerEvent.taskId), newer(workerEvents[workerEvent.id]?.seq, workerEvent.seq) else { return }
            workerEvents[workerEvent.id] = workerEvent
            touch("event", workerEvent.id)
            for field in workerEvent.truncated ?? [] { needText(TextNeed(kind: "worker_event", id: workerEvent.id, field: field, seq: workerEvent.seq)) }
        case .deleted(let d):
            // Removed for good on the host (#405): gone here, from search too, and never kept again.
            switch d.kind {
            case "message":
                deletedMessages.insert(d.id)
                bubbles.removeAll { $0.id == d.id && $0.seq != nil }
                drop("message", d.id)
            case "task":
                deletedTasks.insert(d.id)
                tasks[d.id] = nil
                drop("task", d.id)
            case "worker_event":
                workerEvents[d.id] = nil
                drop("event", d.id)
            case "amendment":
                amendments[d.id] = nil
                drop("amendment", d.id)
            default: break
            }
            textNeeds.removeAll { $0.id == d.id }
            metaDirty = true
        case .readState(let read) where read.threadId == "main":
            if newer(readCursor?.seq, read.seq ?? 0) { readCursor = read; touch("read", read.threadId) }
        case .readState(let read):
            if newer(threadReads[read.threadId]?.seq, read.seq ?? 0) { threadReads[read.threadId] = read; touch("read", read.threadId) }
        default:
            break
        }
    }

    /// Placed by `ts`, ties in arrival order: pages, live updates and sends can interleave out of Mac order. A stored
    /// message is written to the history; one still in the outbox is drawn from there.
    private func merge(_ bubble: Bubble) {
        bubbles.removeAll { $0.id == bubble.id }
        bubbles.insert(bubble, at: bubbles.lastIndex { $0.ts <= bubble.ts }.map { $0 + 1 } ?? 0)
        if bubble.seq != nil { touch("message", bubble.id) }
    }

    private func touch(_ kind: String, _ id: String) {
        let key = HistoryStore.Key(kind: kind, id: id)
        dirty.insert(key)
        removed.remove(key)
    }

    private func drop(_ kind: String, _ id: String) {
        let key = HistoryStore.Key(kind: kind, id: id)
        removed.insert(key)
        dirty.remove(key)
    }

    /// After a whole catch-up every task the host has is held, so steps and changes whose task is not are what a deleted
    /// thread left (a page brought them before its tasks, then the thread was deleted): they go, from search too.
    private func collectOrphans() {
        for a in amendments.values where tasks[a.taskId] == nil { amendments[a.id] = nil; drop("amendment", a.id) }
        for w in workerEvents.values where tasks[w.taskId] == nil { workerEvents[w.id] = nil; drop("event", w.id) }
        textNeeds.removeAll { !holds($0) }
    }

    // MARK: Long text (#405)

    /// A field the host cut to send: fetched whole, a slice at a time, while `.paired`; until then history is not complete.
    private func needText(_ need: TextNeed) {
        textNeeds.removeAll { $0.kind == need.kind && $0.id == need.id && $0.field == need.field }
        textNeeds.append(need)
        historySynced = false
        requestText()
    }

    private func requestText(offset: Int = 0) {
        guard state == .paired, historySupported == true else { return }
        if textFetch == nil {
            guard let next = textNeeds.first else { return }
            textFetch = (next, Data())
        }
        guard let fetch = textFetch else { return }
        // No answer in 20 s (or a send that did not go): the field starts over; the need stays until its text is in.
        textDeadline?.cancel()
        textDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.textFetch?.need == fetch.need else { return }
            self.textFetch = nil
            self.requestText()
        }
        Task { [weak self] in
            if await self?.sendNow(.textRequest(TextRequestData(kind: fetch.need.kind, id: fetch.need.id, field: fetch.need.field, offset: offset))) == false {
                self?.textError = String(localized: "Couldn't ask the host for a long message. Trying again.")
            }
        }
    }

    /// The held record that `need` would fill still has that version (`seq`).
    private func holds(_ need: TextNeed) -> Bool {
        switch need.kind {
        case "message": bubbles.contains { $0.id == need.id && $0.seq == need.seq }
        case "task": tasks[need.id]?.seq == need.seq
        case "amendment": amendments[need.id]?.seq == need.seq
        default: workerEvents[need.id]?.seq == need.seq
        }
    }

    private func receive(_ slice: TextSliceData) {
        guard var fetch = textFetch, fetch.need.kind == slice.kind, fetch.need.id == slice.id, fetch.need.field == slice.field,
              slice.offset == fetch.bytes.count else { return }
        textDeadline?.cancel()
        // A record no longer held as that version (a newer one replaced it, bringing its own need if still cut; or its
        // thread was deleted) needs nothing more. Anything else that went wrong keeps the need and asks again later.
        guard holds(fetch.need) else { textFetch = nil; textNeeds.removeAll { $0 == fetch.need }; return textDone() }
        guard slice.error == nil, slice.seq == fetch.need.seq, let data = Data(base64Encoded: slice.data) else {
            textError = slice.error ?? String(localized: "A long message didn't arrive whole. Trying again.")
            textFetch = nil
            textNeeds.append(textNeeds.removeFirst()) // the next one first; this one again after it
            textDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.requestText()
            }
            return
        }
        fetch.bytes.append(data)
        textFetch = fetch
        if fetch.bytes.count < slice.total, !data.isEmpty { return requestText(offset: fetch.bytes.count) }
        guard fetch.bytes.count == slice.total, let text = String(data: fetch.bytes, encoding: .utf8) else {
            textError = String(localized: "A long message didn't arrive whole. Trying again.")
            textFetch = nil
            return requestText()
        }
        finishText(text)
    }

    /// The whole text replaces the cut one in the held record (only while it is still that version), then the next field.
    private func finishText(_ text: String) {
        guard let need = textFetch?.need else { return }
        textFetch = nil
        textNeeds.removeAll { $0 == need }
        textError = nil
        do {
            switch need.kind {
            case "message":
                if var b = bubbles.first(where: { $0.id == need.id }), b.seq == need.seq { b.text = text; b.truncated = nil; merge(b) }
            case "task":
                if var t = tasks[need.id], t.seq == need.seq {
                    switch need.field { case "instruction": t.instruction = text; case "result": t.result = text; default: t.error = text }
                    t.truncated = t.truncated?.filter { $0 != need.field }
                    tasks[need.id] = t; touch("task", need.id)
                }
            case "amendment":
                if var a = amendments[need.id], a.seq == need.seq { a.instruction = text; a.truncated = nil; amendments[need.id] = a; touch("amendment", need.id) }
            default:
                if var w = workerEvents[need.id], w.seq == need.seq { w.body = text; w.truncated = nil; workerEvents[need.id] = w; touch("event", need.id) }
            }
        }
        textDone()
    }

    /// History is complete once caught up with nothing cut left; the next field, if any.
    private func textDone() {
        if textNeeds.isEmpty, textFetch == nil { historySynced = historySupported == true && !catchingUp && cursor != nil && !holdsCutText }
        saveMeta()
        requestText()
    }

    /// Any held record still carries only the head of a field.
    private var holdsCutText: Bool {
        bubbles.contains { $0.truncated == true } || tasks.values.contains { !($0.truncated ?? []).isEmpty }
            || amendments.values.contains { !($0.truncated ?? []).isEmpty } || workerEvents.values.contains { !($0.truncated ?? []).isEmpty }
    }

    // MARK: Cache

    /// `keepPending`: sent bubbles whose stored copy has not arrived survive a `reset`. Only a host without `history-v1`
    /// resets this way, or a pairing being removed; the disk follows at the next write.
    private func clearMirror(keepPending: Bool) {
        for b in bubbles where b.seq != nil { drop("message", b.id) }
        topics.keys.forEach { drop("topic", $0) }
        tasks.keys.forEach { drop("task", $0) }
        amendments.keys.forEach { drop("amendment", $0) }
        workerEvents.keys.forEach { drop("event", $0) }
        threadReads.keys.forEach { drop("read", $0) }
        drop("read", "main")
        bubbles = keepPending ? bubbles.filter { $0.seq == nil } : []
        topics = [:]
        tasks = [:]
        amendments = [:]
        workerEvents = [:]
        readCursor = nil
        threadReads = [:]
        deletedThreads = []
        page = nil
        search = nil
        controlResults = [:]
    }

    /// The sync state kept beside the records, written in the same transaction as them.
    private struct Meta: Codable {
        var cursor: Int?
        var historySynced: Bool?
        var jobs: Bool?
        var threads: Bool?
        var jobList: [JobListData.Job]?
        var jobListAt: Int?
        var threadList: [ThreadData]?
        var archivedThreads: [ThreadData]?
        var mainRow: ThreadData?
        var mainChat: Bool?
        var historySupported: Bool?
        var deletedTasks: [String]?
        var hostSettings: HostSettingsData?
        var deletedMessages: [String]?
    }
    @ObservationIgnored private var metaDirty = false
    /// The history is being read from disk; `start()` waits for it.
    private(set) var historyLoading = false
    @ObservationIgnored private var startWanted = false
    /// A history write is in flight; `afterCommit` runs once what it and the writes before it carried is durable.
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var afterCommit: [@MainActor () -> Void] = []
    /// The last history write failed (a full disk): it is retried, and the chat says history is not saved.
    private(set) var historyWriteFailed = false

    private func saveMeta() {
        metaDirty = true
        scheduleSave()
    }

    /// Opens this pairing's history and draws the mirror from it before any network request. A first launch after the
    /// update moves the window cache (`MirrorCache`) in and backfills the rest from the start, merging (#405).
    private func openHistory(owner: String, adoptFrom: String? = nil) {
        let store = HistoryStore(owner: owner, adoptFrom: adoptFrom)
        history = store
        if store.isEmpty, let legacy = MirrorCache.shared.load(owner: owner) {
            restore(legacy)
            // Its cursor counted the window only: the whole history comes again from 0, merged by the upsert rule.
            cursor = nil
            historySynced = false
            for b in bubbles where b.seq != nil { touch("message", b.id) }
            topics.keys.forEach { touch("topic", $0) }
            tasks.keys.forEach { touch("task", $0) }
            amendments.keys.forEach { touch("amendment", $0) }
            workerEvents.keys.forEach { touch("event", $0) }
            if readCursor != nil { touch("read", "main") }
            metaDirty = true
            // The window cache stays until its records are durable in the history; a failed move tries again next launch.
            flush { MirrorCache.shared.wipe() }
            return
        }
        // The records load off the main actor, in one pass on the store's queue (#405): the list shows from its cached rows
        // at once, and the link dials once the history is in, so nothing from the host races the load.
        historyLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            var after: Int64 = 0
            while true {
                let batch = store.load(after: after)
                guard !batch.records.isEmpty else { break }
                after = batch.last
                let loaded = Self.decode(batch.records)
                guard await MainActor.run(body: { self?.merge(loaded, from: store) ?? false }) else { return }
            }
            await MainActor.run { self?.adopted(from: store) }
        }
        if let meta = store.meta("sync", as: Meta.self) {
            cursor = meta.cursor
            historySynced = meta.historySynced == true
            cacheHasJobs = meta.jobs == true
            cacheHasThreads = meta.threads == true
            jobs = meta.jobList ?? []
            jobsUpdated = meta.jobListAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            threadList = meta.threadList ?? []
            archivedThreads = meta.archivedThreads ?? []
            mainRow = meta.mainRow
            mainChat = meta.mainChat
            historySupported = meta.historySupported
            deletedTasks = Set(meta.deletedTasks ?? [])
            hostSettings = meta.hostSettings
            deletedMessages = Set(meta.deletedMessages ?? [])
        }
    }

    /// What `loadAll` held, decoded.
    private struct Loaded: Sendable {
        var bubbles: [Bubble] = []
        var topics: [String: TopicData] = [:]
        var tasks: [String: TaskData] = [:]
        var amendments: [String: AmendmentData] = [:]
        var events: [String: WorkerEventData] = [:]
        var reads: [String: ReadStateData] = [:]
    }

    nonisolated private static func decode(_ records: [HistoryStore.Record]) -> Loaded {
        let decoder = JSONDecoder()
        var out = Loaded()
        for r in records {
            switch r.kind {
            case "message": if let b = try? decoder.decode(Bubble.self, from: r.json) { out.bubbles.append(b) }
            case "topic": if let t = try? decoder.decode(TopicData.self, from: r.json) { out.topics[t.id] = t }
            case "task": if let t = try? decoder.decode(TaskData.self, from: r.json) { out.tasks[t.id] = t }
            case "amendment": if let a = try? decoder.decode(AmendmentData.self, from: r.json) { out.amendments[a.id] = a }
            case "event": if let w = try? decoder.decode(WorkerEventData.self, from: r.json) { out.events[w.id] = w }
            case "read": if let read = try? decoder.decode(ReadStateData.self, from: r.json) { out.reads[read.threadId] = read }
            default: break
            }
        }
        out.bubbles.sort { $0.ts < $1.ts }
        return out
    }

    /// One loaded batch joins what this run holds (sent bubbles from the outbox, earlier batches); false once this store
    /// is no longer the pairing's. The main actor takes each batch in turn, so the app stays responsive while it loads.
    private func merge(_ loaded: Loaded, from store: HistoryStore) -> Bool {
        guard history === store else { return false }
        receiving = true
        let have = Set(bubbles.map(\.id))
        bubbles += loaded.bubbles.filter { !have.contains($0.id) }
        bubbles.sort { $0.ts < $1.ts }
        topics.merge(loaded.topics) { held, _ in held }
        deletedThreads.formUnion(loaded.topics.values.filter { $0.deleted == true }.map(\.id))
        tasks.merge(loaded.tasks) { held, _ in held }
        amendments.merge(loaded.amendments) { held, _ in held }
        workerEvents.merge(loaded.events) { held, _ in held }
        if let main = loaded.reads["main"] { readCursor = main }
        threadReads.merge(loaded.reads.filter { $0.key != "main" }) { held, _ in held }
        receiving = false
        rebuildTimeline()
        return true
    }

    /// The whole history is loaded: long text still cut is fetched again, and the link may dial.
    private func adopted(from store: HistoryStore) {
        guard history === store else { return }
        historyLoading = false
        // Long text still cut when the app last ran: fetched again from the start.
        for b in bubbles where b.truncated == true { if let seq = b.seq { textNeeds.append(TextNeed(kind: "message", id: b.id, field: "text", seq: seq)) } }
        for t in tasks.values { for f in t.truncated ?? [] { textNeeds.append(TextNeed(kind: "task", id: t.id, field: f, seq: t.seq)) } }
        for a in amendments.values { for f in a.truncated ?? [] { textNeeds.append(TextNeed(kind: "amendment", id: a.id, field: f, seq: a.seq)) } }
        for w in workerEvents.values { for f in w.truncated ?? [] { textNeeds.append(TextNeed(kind: "worker_event", id: w.id, field: f, seq: w.seq)) } }
        if !textNeeds.isEmpty { historySynced = false }
        updateBadge()
        if startWanted { startWanted = false; start() }
    }

    /// The window cache of builds before #405, read once to move it into the history.
    private func restore(_ snapshot: MirrorCache.Snapshot) {
        cursor = snapshot.cursor
        readCursor = snapshot.readCursor
        bubbles = snapshot.messages.sorted { $0.ts < $1.ts }
        topics = Dictionary(snapshot.topics.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        tasks = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        amendments = Dictionary(snapshot.amendments.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        workerEvents = Dictionary(snapshot.workerEvents.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cacheHasJobs = snapshot.jobs == true
        cacheHasThreads = snapshot.threads == true
        jobs = snapshot.jobList ?? []
        jobsUpdated = snapshot.jobListAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
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

    /// Writes what changed since the last write, and the sync state, in one transaction: only those records, never the
    /// whole history.
    /// `committed` runs once this write is durable (the window cache's move waits for it).
    private func flush(committed: (@MainActor () -> Void)? = nil) {
        saveTask?.cancel()
        saveTask = nil
        if let committed { afterCommit.append(committed) }
        // One write at a time: the next waits for this one's commit, so no later batch (and its cursor) lands without it.
        guard let history, !writing, !dirty.isEmpty || !removed.isEmpty || metaDirty else {
            if !writing, !afterCommit.isEmpty { let done = afterCommit; afterCommit = []; done.forEach { $0() } }
            return
        }
        let encoder = JSONEncoder()
        let byId = Dictionary(bubbles.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var upserts: [HistoryStore.Record] = []
        for key in dirty {
            switch key.kind {
            case "message":
                guard let b = byId[key.id], let seq = b.seq, let json = try? encoder.encode(b) else { continue }
                upserts.append(.init(kind: key.kind, id: key.id, seq: seq, ts: b.ts, thread: b.threadId, topic: b.topicId, text: b.text, json: json))
            case "topic":
                guard let t = topics[key.id], let json = try? encoder.encode(t) else { continue }
                upserts.append(.init(kind: key.kind, id: key.id, seq: t.seq, ts: t.created, thread: nil, topic: t.id, text: nil, json: json))
            case "task":
                guard let t = tasks[key.id], let json = try? encoder.encode(t) else { continue }
                upserts.append(.init(kind: key.kind, id: key.id, seq: t.seq, ts: t.created, thread: nil, topic: t.topicId, text: nil, json: json))
            case "amendment":
                guard let a = amendments[key.id], let json = try? encoder.encode(a) else { continue }
                upserts.append(.init(kind: key.kind, id: key.id, seq: a.seq, ts: 0, thread: nil, topic: nil, text: nil, json: json))
            case "event":
                guard let w = workerEvents[key.id], let json = try? encoder.encode(w) else { continue }
                upserts.append(.init(kind: key.kind, id: key.id, seq: w.seq, ts: w.created, thread: nil, topic: tasks[w.taskId]?.topicId, text: w.body, json: json))
            case "read":
                guard let r = key.id == "main" ? readCursor : threadReads[key.id], let json = try? encoder.encode(r) else { continue }
                upserts.append(.init(kind: key.kind, id: key.id, seq: r.seq ?? 0, ts: 0, thread: key.id, topic: nil, text: nil, json: json))
            default: continue
            }
        }
        var meta: [String: Data?] = [:]
        if metaDirty {
            meta["sync"] = try? encoder.encode(Meta(cursor: cursor, historySynced: historySynced, jobs: cacheHasJobs, threads: cacheHasThreads,
                                                    jobList: jobs, jobListAt: jobsUpdated.map { Int($0.timeIntervalSince1970 * 1000) },
                                                    threadList: threadList, archivedThreads: archivedThreads, mainRow: mainRow, mainChat: mainChat,
                                                    historySupported: historySupported, deletedTasks: Array(deletedTasks), hostSettings: hostSettings,
                                                    deletedMessages: Array(deletedMessages)))
        }
        // Held records are written as they are now: the in-memory upsert rule already decided, so the disk follows it.
        // What this batch carried is written again with the next one unless it committed, so a failed write (a full disk)
        // leaves no gap behind a cursor that moved on: the cursor travels in the same transaction.
        let batch = (dirty, removed, metaDirty), waiting = afterCommit
        dirty = []
        removed = []
        metaDirty = false
        afterCommit = []
        writing = true
        history.write(upserts: upserts, deletes: Array(batch.1), meta: meta, force: true) { ok in
            Task { @MainActor [weak self, weak history] in
                guard let self, let history, self.history === history else { return }
                self.writing = false
                self.historyWriteFailed = !ok
                if ok {
                    waiting.forEach { $0() }
                    if !self.dirty.isEmpty || !self.removed.isEmpty || self.metaDirty { self.scheduleSave() }
                    return
                }
                // Not rewritten over newer state: a key changed meanwhile is already dirty again.
                self.dirty.formUnion(batch.0.subtracting(self.removed))
                self.removed.formUnion(batch.1.subtracting(self.dirty))
                self.metaDirty = self.metaDirty || batch.2
                self.afterCommit = waiting + self.afterCommit
                try? await Task.sleep(for: .seconds(5))
                self.scheduleSave()
            }
        }
    }

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
