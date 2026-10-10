import Foundation
import os
import ProjectXCore
import YorozuWire

/// The v2 Engine behind the relay (docs/ios-relay-contract.md, 0.7): `message`, `sync_request`, `read_state`,
/// `task_control`, `search_request`, `page_request`, the plain `thread_list` and the `attachment_*` requests in; `receipt`,
/// `admission_status`, `sync_delta`, `task_control_result`, `search_result`, `attachment_progress` and
/// `attachment_download_chunk` out. Records travel by change sequence (`Store.changes`) with their files' descriptors.
/// Jobs (#319, `jobs-v1`): `job_control` and job-targeted `message` in, `job_list` out through `RelayHost.publishJobs`.
/// A job run's trigger (`job_run`) never reaches phones; the other job-only kinds go only to phones that take `jobs-v1`
/// (`RelayHost` strips them for the rest), and the working flag ignores work in job topics (open question 10).
actor EngineBridge: RelayBackend {
    /// The threads this Mac has: one, `main`, holding every v2 message as the Mac's main chat shows them.
    static let threads: Set<String> = ["main"]
    private static let log = Logger(subsystem: "to.yumi.yorozu", category: "relay")

    private let engine: Engine
    private let mode: RuntimeMode
    /// The latest change sequence the live updates reached; nil before the first publish.
    private var published: Int64?
    private var working = false, routing = false
    /// The newest message created when phones were last told (#320); nil before the first publish, which only sets it, so
    /// messages from before launch never notify.
    private var alerted: Double?
    private var main = ThreadSummary.main(0)
    /// The last 64 `task_control` results, oldest first, for replays of the same `requestId`.
    private var controlled: [TaskControlResultData] = []
    /// The last 64 `job_control` answers, keyed by event id, for replays.
    private var jobControls: [AdmissionStatusData] = []
    /// Next runs for `job_list`; nil before jobs start.
    private let scheduler: JobScheduler?
    /// What the last job list was read at (change sequence, next runs) and when: read again only when either moved or
    /// 5 s passed (summaries and pauses of unscheduled jobs move neither).
    private var jobsRead: (latest: Int64, next: [String: Date], at: ContinuousClock.Instant)?

    /// Awaited before a phone message reaches the Engine (the model metadata retry, #312).
    private let prepare: @Sendable () async -> Void
    /// Phone uploads waiting for their commit (#316).
    private var staging: UploadStaging
    /// Where phone thumbnails are cached.
    private let thumbs: URL
    /// Attachment descriptors by id, from the last snapshot read; refreshed when a download names an unknown id.
    private var known: [String: Attachment] = [:]

    /// The relay runs in live mode only, so staging and thumbnails sit beside the live data:
    /// `~/Library/Application Support/<bundle id>/uploads` and `~/Library/Caches/<bundle id>/thumbs`.
    init(engine: Engine, mode: RuntimeMode, scheduler: JobScheduler?, prepare: @escaping @Sendable () async -> Void = {}) {
        self.engine = engine; self.mode = mode; self.scheduler = scheduler; self.prepare = prepare
        let fm = FileManager.default, bundle = Bundle.main.bundleIdentifier ?? "to.yumi.yorozu"
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundle, isDirectory: true)
        staging = UploadStaging(root: support.appendingPathComponent("uploads", isDirectory: true))
        thumbs = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("thumbs", isDirectory: true)
    }

    func handle(_ e: YorozuEvent, from device: String) async -> [YorozuEvent] {
        switch e.payload {
        case .message(let m): return [await admit(m, id: e.id, ts: e.ts)]
        case .attachmentChunk(let c): return [await stage(c, request: e.id, device: device)]
        case .attachmentCommit(let c): return [await commit(c, id: e.id, ts: e.ts, device: device)]
        case .attachmentDownloadRequest(let r): return [await download(r)]
        case .syncRequest(let r): return [await reply(r, thread: r.threadId ?? (e.threadId.isEmpty ? "main" : e.threadId))]
        case .readState(let r):
            // Forward-only in the Store; a cursor that moved reaches every phone as a record in the next live update.
            if Self.threads.contains(r.threadId) { _ = try? await engine.store.markRead(thread: r.threadId, message: r.messageId) }
            return []
        case .taskControl(let c):
            // A replayed request gets its first result again, never a second run.
            if let done = controlled.last(where: { $0.requestId == c.requestId }) { return [.control(.taskControlResult(done))] }
            let o = await (c.action == .stop ? engine.stopTask(id: c.taskId) : engine.retryTask(id: c.taskId))
            let result = TaskControlResultData(requestId: c.requestId, taskId: c.taskId, accepted: o.accepted, text: o.text,
                                               notice: o.notice.map(Self.notice), messageId: o.messageID)
            controlled = Array((controlled + [result]).suffix(64))
            return [.control(.taskControlResult(result))]
        case .searchRequest(let r): return [await search(r)]
        case .pageRequest(let r): return [await page(r)]
        case .threadList: return [.control(.threadList(ThreadListData(threads: [main])))]
        case .jobControl(let c): return [await jobControl(c, id: e.id, ts: e.ts)]
        default: return []
        }
    }

    /// Called on every poll with the latest snapshot: live updates for the changes past the last published sequence,
    /// or a flag-only one when the working or routing flag moved, and a push for each new message `Message.alert` names.
    /// The first call only sets the starting point.
    func publish(_ s: Snapshot, to host: RelayHost) async {
        let jobs = Set(((try? await engine.store.jobRecords()) ?? []).map(\.topicID))
        let working = s.work.contains { $0.active && !jobs.contains($0.topicID) }, routing = await engine.routing
        remember(s.attachments)
        // Every main-timeline message goes out on the main thread, so that is the thread a push names.
        if let alerted { for m in s.messages where m.created > alerted { if let a = m.alert { await host.notify(a, threadID: main.id, eventID: m.id, excerpt: m.notificationExcerpt) } } }
        alerted = max(alerted ?? 0, s.messages.last?.created ?? 0)
        main = .main((s.messages.last(where: \.onMainTimeline)?.created ?? 0) * 1000)
        await host.setMain(main)
        guard let bounds = try? await engine.store.cursorBounds() else { return }
        await publishJobs(latest: bounds.latest, to: host)
        guard var after = published else { published = bounds.latest; self.working = working; self.routing = routing; return }
        guard bounds.latest != after || working != self.working || routing != self.routing else { return }
        let flags = (self.working, self.routing)
        self.working = working; self.routing = routing
        var updates: [YorozuEvent] = []
        // A poll that could not publish anything leaves the flags to the next one.
        defer { if updates.isEmpty { (self.working, self.routing) = flags } }
        do {
            repeat {
                let p = try await engine.store.changes(after: after, limit: 200)
                let (events, next, more) = Self.fit(p, thread: "main", files: Self.carriesFiles(p.changes) ? await files() : [:])
                updates.append(delta(events, thread: "main", after: after, latest: next))
                after = next
                if !more { break }
            } while true
        } catch {
            // Nothing published past `after`; the next poll tries again from there.
            Self.log.error("live update unreadable: \(error.localizedDescription, privacy: .public)")
        }
        published = after
        await host.broadcast(updates)
    }

    // MARK: Requests

    /// `ts` (the phone's send time, epoch ms) is kept as the message's `sentAt` (#314).
    private func admit(_ m: MessageData, id: String, ts: Int) async -> YorozuEvent {
        func reject(_ reason: String) -> YorozuEvent { .control(.admissionStatus(AdmissionStatusData(eventId: id, status: .rejected, reason: reason))) }
        let receipt = YorozuEvent.control(.receipt(ReceiptData(eventId: id)))
        guard id.range(of: #"^[A-Za-z0-9-]{1,64}\z"#, options: .regularExpression) != nil else { return reject(String(localized: "Invalid message id.")) }
        guard m.attachments.isEmpty else { return reject(String(localized: "Update Yorozu on this device to send attachments.")) }
        guard mode.permitsInput(fixtureAcknowledged: false) else { return reject(String(localized: "The host is in fixture mode and doesn't take messages from client devices.")) }
        // A resend or a relay replay of something already stored: the receipt is all it needs.
        if await exists(id) { return receipt }
        // Past its deadline (the phone sets send time + 24 h): never routed late, the phone shows Not delivered (#314).
        if let deadline = m.admissionDeadline, deadline < Self.now {
            return .control(.admissionStatus(AdmissionStatusData(eventId: id, status: .expired, reason: "The host was offline for more than 24 hours.")))
        }
        await prepare()
        // Text, id and send time only: no model may learn which device a message came from (#313). A job's own input
        // goes to that job's sub-chat without the secretary (#319).
        do {
            if let job = m.jobId { try await engine.sendToJob(jobID: job, body: m.text, id: id, sentAt: Double(ts) / 1000) }
            else {
                // A reply names the message it answers; its topic then holds this one (owner, 2026-10-09).
                let replyTo = m.replyTo.flatMap { $0.range(of: #"^[A-Za-z0-9-]{1,64}\z"#, options: .regularExpression) != nil ? $0 : nil }
                try await engine.send(m.text, id: id, sentAt: Double(ts) / 1000, replyTo: replyTo)
            }
            return receipt
        } catch { return await exists(id) ? receipt : reject(error.localizedDescription) }
    }

    // MARK: Jobs (#319)

    /// Pause, Resume, Delete (through `jobs.toml`, so the next `job_list` shows the change) or Run now. Answered
    /// `accepted`, or `rejected` with the reason; a replayed event id gets its first answer again, never a second run.
    /// A tap sent (`ts`, epoch ms) more than 2 minutes ago is refused: the phone no longer shows what it acted on.
    private func jobControl(_ c: JobControlData, id: String, ts: Int) async -> YorozuEvent {
        if let done = jobControls.last(where: { $0.eventId == id }) { return .control(.admissionStatus(done)) }
        var reason: String?
        if Self.now - ts > 120_000 { reason = String(localized: "That tap reached the host too late.") }
        else if !mode.permitsInput(fixtureAcknowledged: false) { reason = String(localized: "The host is in fixture mode and doesn't take messages from client devices.") }
        else {
            do {
                switch c.action {
                case .pause: try await engine.pauseJob(c.jobId)
                case .resume: try await engine.resumeJob(c.jobId)
                case .delete: try await engine.deleteJob(c.jobId)
                case .runNow: if case .skipped(let why) = try await engine.runJobNow(c.jobId) { reason = String(localized: "It didn't run: ") + Engine.skipText(why) }
                }
            } catch { reason = error.localizedDescription }
        }
        let status = AdmissionStatusData(eventId: id, status: reason == nil ? .accepted : .rejected, reason: reason)
        jobControls = Array((jobControls + [status]).suffix(64))
        return .control(.admissionStatus(status))
    }

    /// The job list from `Engine.jobStatus` and the scheduler's next runs, read when the change sequence or the next runs
    /// moved, or 5 s passed; `RelayHost` sends it only when it differs from the last one.
    private func publishJobs(latest: Int64, to host: RelayHost) async {
        guard let scheduler else { return }
        let next = await scheduler.nextRuns
        if let read = jobsRead, read.latest == latest, read.next == next, read.at.duration(to: .now) < .seconds(5) { return }
        jobsRead = (latest, next, .now)
        let ms = { (d: Date) in Int(d.timeIntervalSince1970 * 1000) }
        await host.publishJobs(JobListData(jobs: await engine.jobStatus(nextRuns: next).map {
            JobListData.Job(id: $0.id, name: $0.name, summary: $0.summary, nextRun: $0.nextRun.map(ms), lastRun: $0.lastRun.map(ms),
                            lastResult: $0.lastResult, lastNotable: $0.lastNotable, state: $0.state.rawValue, topicId: $0.topicID)
        }))
    }

    /// Only after a failed send: a keyed lookup of the id.
    private func exists(_ id: String) async -> Bool { ((try? await engine.store.message(id: id)) ?? nil) != nil }

    // MARK: Attachments (#316)

    /// One upload chunk into staging. A chunk for a message already stored (a relay replay after the commit) is
    /// answered as complete without staging anything.
    private func stage(_ c: AttachmentChunkData, request: String, device: String) async -> YorozuEvent {
        let stored = AttachmentDescriptor.isID(c.messageId) ? await exists(c.messageId) : false
        let done = stored ? (nextOffset: c.totalBytes, reason: nil) : staging.chunk(c, device: device)
        return .control(.attachmentProgress(AttachmentProgressData(requestId: request, messageId: c.messageId, index: c.index, nextOffset: done.nextOffset, reason: done.reason)))
    }

    /// The text and its staged files as one message, by the host checks of `message` plus: the files valid (1–10,
    /// each within the limits) and each staged whole, else `attachment_progress` for the first one that is not.
    /// Idempotent by message id, so a relay replay or a resend gets the `receipt` again.
    private func commit(_ c: AttachmentCommitData, id: String, ts: Int, device: String) async -> YorozuEvent {
        func reject(_ reason: String) -> YorozuEvent { .control(.admissionStatus(AdmissionStatusData(eventId: id, status: .rejected, reason: reason))) }
        let receipt = YorozuEvent.control(.receipt(ReceiptData(eventId: id)))
        guard AttachmentDescriptor.isID(id) else { return reject(String(localized: "Invalid message id.")) }
        guard (1...MessageAttachment.maxCount).contains(c.attachments.count), c.attachments.allSatisfy({ $0.isValid && $0.id == nil }) else {
            return reject(String(localized: "Up to \(MessageAttachment.maxCount) files of at most 50 MB each."))
        }
        guard mode.permitsInput(fixtureAcknowledged: false) else { return reject(String(localized: "The host is in fixture mode and doesn't take messages from client devices.")) }
        if await exists(id) { staging.remove(device: device, message: id); return receipt }
        if c.admissionDeadline < Self.now {
            staging.remove(device: device, message: id)
            return .control(.admissionStatus(AdmissionStatusData(eventId: id, status: .expired, reason: "The host was offline for more than 24 hours.")))
        }
        switch staging.assemble(c.attachments, device: device, message: id) {
        case .failed(let reason): return .control(.attachmentProgress(AttachmentProgressData(requestId: id, messageId: id, index: 0, nextOffset: 0, reason: reason)))
        case .missing(let index, let offset): return .control(.attachmentProgress(AttachmentProgressData(requestId: id, messageId: id, index: index, nextOffset: offset)))
        case .ready(let urls):
            await prepare()
            let files = zip(urls, c.attachments).map { PendingFile(url: $0, name: $1.name, mime: $1.mime) }
            // Staging stays after a refusal, so a Resend commits again without uploading again; pruning clears it.
            do { try await engine.send(c.text, attachments: files, id: id, sentAt: Double(ts) / 1000) }
            catch { return await exists(id) ? receipt : reject(error.localizedDescription) }
            staging.remove(device: device, message: id)
            return receipt
        }
    }

    /// One chunk of an attachment or of its thumbnail from `offset`. A file that is gone or no longer matches its size
    /// on record is `attachment-unavailable`.
    private func download(_ r: AttachmentDownloadRequestData) async -> YorozuEvent {
        let thumbnail = r.thumbnail == true
        func answer(_ total: Int = 0, _ sha: String = "", data: Data = Data(), reason: String? = nil) -> YorozuEvent {
            .control(.attachmentDownloadChunk(AttachmentDownloadChunkData(attachmentId: r.attachmentId, thumbnail: thumbnail ? true : nil, offset: r.offset,
                                                                          totalBytes: total, data: data.base64EncodedString(), sha256: sha, reason: reason)))
        }
        guard AttachmentDescriptor.isID(r.attachmentId), r.offset >= 0 else { return answer(reason: AttachmentReason.invalid) }
        if known[r.attachmentId] == nil, let s = try? await engine.snapshot() { remember(s.attachments) }
        guard let a = known[r.attachmentId], let url = await engine.attachmentURL(r.attachmentId),
              (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 == a.bytes else { return answer(reason: AttachmentReason.unavailable) }
        var file = url, total = Int(a.bytes), sha = a.sha256
        if thumbnail {
            guard let thumb = await Thumbnails.jpeg(for: url, id: a.id, in: thumbs),
                  let digest = try? AttachmentDescriptor.digest(of: thumb) else { return answer(reason: AttachmentReason.thumbnailUnavailable) }
            (file, total, sha) = (thumb, digest.bytes, digest.sha256)
        }
        guard r.offset <= total else { return answer(total, sha, reason: AttachmentReason.invalid) }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(r.offset))
            return answer(total, sha, data: try handle.read(upToCount: MessageAttachment.downloadChunkBytes) ?? Data())
        } catch { return answer(reason: AttachmentReason.unavailable) }
    }

    private func remember(_ attachments: [Attachment]) {
        guard attachments.count != known.count else { return }
        known = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Descriptors by owning message or worker event, read after the records they go with (attachment rows are written
    /// with their owner, or re-stamp it), so every record sent carries its files.
    private func files() async -> [String: [AttachmentDescriptor]] {
        guard let s = try? await engine.snapshot() else { return [:] }
        remember(s.attachments)
        return Self.files(s.attachments)
    }

    private static func files(_ attachments: [Attachment]) -> [String: [AttachmentDescriptor]] {
        var out: [String: [AttachmentDescriptor]] = [:]
        for a in attachments {
            guard let owner = a.messageID ?? a.eventID else { continue }
            out[owner, default: []].append(AttachmentDescriptor(id: a.id, name: a.name, mime: a.mime, bytes: Int(a.bytes), sha256: a.sha256))
        }
        return out
    }

    /// A reply page: the window's changes after the phone's cursor, or the window from its start (`reset`) when the
    /// cursor is absent, zero or stale. Always answered; an unreadable store gives an error page.
    private func reply(_ r: SyncRequestData, thread: String) async -> YorozuEvent {
        let routing = await engine.routing
        guard Self.threads.contains(thread) else { return delta([], thread: thread, after: r.afterSeq.map(Int64.init), routing: routing, error: String(localized: "Unknown thread.")) }
        do {
            let bounds = try await engine.store.cursorBounds()
            let cursor = Int64(r.afterSeq ?? 0)
            let reset = cursor <= 0 || cursor > bounds.latest || bounds.floor.map { cursor < $0 } == true
            let p = try await engine.store.changes(after: reset ? 0 : cursor, limit: 200)
            let (events, next, more) = Self.fit(p, thread: thread, files: Self.carriesFiles(p.changes) ? await files() : [:])
            return delta(events, thread: thread, after: r.afterSeq.map(Int64.init), latest: next, more: more, reset: reset, routing: routing)
        } catch {
            Self.log.error("sync_request unreadable: \(error.localizedDescription, privacy: .public)")
            return delta([], thread: thread, after: r.afterSeq.map(Int64.init), routing: routing, error: String(localized: "Couldn't read the chat on the host: \(error.localizedDescription)"))
        }
    }

    /// A page reply: the messages around one message, in or out of the window. It never moves the cursor.
    private func page(_ r: PageRequestData) async -> YorozuEvent {
        let routing = await engine.routing
        guard Self.threads.contains(r.threadId) else { return delta([], thread: r.threadId, routing: routing, requestId: r.requestId, error: String(localized: "Unknown thread.")) }
        do {
            guard let changes = try await engine.store.page(around: r.messageId) else {
                return delta([], thread: r.threadId, routing: routing, requestId: r.requestId, error: String(localized: "Message not found."))
            }
            let files = await files()
            let page = delta(changes.filter(Self.sent).map { Self.record($0, thread: r.threadId, files: files).event }, thread: r.threadId, routing: routing, requestId: r.requestId)
            // 101 capped records could still pass what 256 chunks carry.
            guard (try? JSONEncoder().encode(page).count).map({ $0 <= Self.hardCap }) == true else {
                return delta([], thread: r.threadId, routing: routing, requestId: r.requestId, error: String(localized: "That part of the chat is too large to send."))
            }
            return page
        } catch {
            return delta([], thread: r.threadId, routing: routing, requestId: r.requestId, error: String(localized: "Couldn't read the chat on the host: \(error.localizedDescription)"))
        }
    }

    private func search(_ r: SearchRequestData) async -> YorozuEvent {
        let offset = max(0, r.offset ?? 0)
        do {
            let (hits, total) = try await engine.search(r.query, limit: 50, offset: offset)
            let next = offset + hits.count
            return .control(.searchResult(SearchResultData(requestId: r.requestId, hits: hits.map {
                SearchHitData(threadId: $0.threadID, topicId: $0.topicID, taskId: $0.taskID, messageId: $0.messageID, eventId: $0.eventID,
                              snippet: $0.snippet, created: Int($0.created * 1000))
            }, total: total, nextOffset: !hits.isEmpty && next < total ? next : nil)))
        } catch {
            return .control(.searchResult(SearchResultData(requestId: r.requestId, hits: [], total: 0, error: String(localized: "Search failed: \(error.localizedDescription)"))))
        }
    }

    // MARK: Pages and records

    private func delta(_ events: [YorozuEvent], thread: String, after: Int64? = nil, latest: Int64? = nil, more: Bool = false, reset: Bool = false,
                       routing: Bool? = nil, requestId: String? = nil, error: String? = nil) -> YorozuEvent {
        let flag = { (on: Bool) in on ? [thread] : [] }
        return YorozuEvent(id: UUID().uuidString, threadId: thread, ts: Self.now, agentId: "main",
                           payload: .syncDelta(SyncDeltaData(events: events, threadId: thread, workingThreadIds: flag(working), more: more ? true : nil,
                                                             routingThreadIds: flag(routing ?? self.routing), afterSeq: after.map(Int.init),
                                                             latestSeq: latest.map(Int.init), reset: reset ? true : nil, requestId: requestId, error: error)))
    }

    /// The longest prefix of `p` within 200 records and `ChunkData.budget` of encoded events (at least one record), the
    /// next cursor (the last record's seq when changes remain, else `p.latest`) and whether changes remain.
    /// Run triggers are skipped but still consumed, so the cursor passes them (a gap in `seq` is fine).
    private static func fit(_ p: ChangePage, thread: String, files: [String: [AttachmentDescriptor]]) -> (events: [YorozuEvent], next: Int64, more: Bool) {
        var events: [YorozuEvent] = [], bytes = 0, used = 0
        for change in p.changes {
            guard sent(change) else { used += 1; continue }
            let r = record(change, thread: thread, files: files)
            if !events.isEmpty && (events.count == 200 || bytes + r.size > ChunkData.budget) { break }
            events.append(r.event); bytes += r.size; used += 1
        }
        let more = p.more || used < p.changes.count
        return (events, more ? p.changes[used - 1].seq : p.latest, more)
    }

    /// Whether a page has a record that can carry files, so pages of tasks and cursors skip the attachment read.
    private static func carriesFiles(_ changes: [Change]) -> Bool {
        changes.contains { switch $0.record { case .message, .event: true; default: false } }
    }

    /// Everything but a job run's trigger (#319); `RelayHost` strips the other job-only kinds for phones without `jobs-v1`.
    private static func sent(_ change: Change) -> Bool {
        if case .message(let m) = change.record { return m.kind != "job_run" }
        return true
    }

    /// The largest record sent: what 256 chunks carry, less room for the page around it. Worker output has no size
    /// limit, so a bigger record keeps the head of its text and says the rest is on the Mac.
    private static let hardCap = ChunkData.maxCount * ChunkData.slice - 65_536

    private static func record(_ change: Change, thread: String, files: [String: [AttachmentDescriptor]]) -> (event: YorozuEvent, size: Int) {
        let seq = Int(change.seq), ms = { (t: Double) in Int(t * 1000) }
        var e: YorozuEvent
        switch change.record {
        case .message(let m):
            e = event(m.id, thread, ms(m.created), .message(MessageData(role: m.role == "user" ? .user : .agent, text: m.body, done: true,
                failed: m.kind == "failure" ? true : nil, kind: m.kind, topicId: m.topicID, taskId: m.taskID, replyTo: m.replyTo,
                notice: m.notice.map(notice), seq: seq,
                readAt: m.role == "user" ? m.readAt.map(ms) : nil, sentAt: m.sentAt.map(ms), files: files[m.id])))
        case .topic(let t): e = event(t.id, thread, ms(t.created), .topic(TopicData(id: t.id, label: t.label, created: ms(t.created), seq: seq, attachedTo: t.attachedTo)))
        case .work(let w):
            e = event(w.id, thread, ms(w.created), .task(TaskData(id: w.id, topicId: w.topicID, messageId: w.messageID, instruction: w.instruction,
                executor: w.executor, state: w.state, revision: w.revision, suppressed: w.suppressed, error: w.error, result: w.result,
                created: ms(w.created), seq: seq)))
        case .amendment(let a):
            e = event(a.id, thread, now, .amendment(AmendmentData(id: a.id, taskId: a.taskID, messageId: a.messageID, revision: a.revision,
                                                                  instruction: a.instruction, state: a.state, seq: seq)))
        case .event(let w):
            e = event(w.id, thread, ms(w.created), .workerEvent(WorkerEventData(id: w.id, taskId: w.taskID, kind: w.kind, body: w.body, created: ms(w.created), seq: seq, files: files[w.id])))
        case .readCursor(let c): e = event(c.threadID, thread, now, .readState(ReadStateData(threadId: c.threadID, messageId: c.messageID, seq: seq)))
        }
        // Shrinks the long text fields until the record fits; a few passes always do, since each one cuts in proportion.
        for _ in 0..<4 {
            let size = (try? JSONEncoder().encode(e).count) ?? 0
            guard size > hardCap else { return (e, size) }
            let cut = { (s: String) in head(s, Double(hardCap) / Double(size) * 0.9) }
            switch e.payload {
            case .message(var m): m.text = cut(m.text); e.payload = .message(m)
            case .task(var t): t.instruction = cut(t.instruction); t.result = t.result.map(cut); t.error = t.error.map(cut); e.payload = .task(t)
            case .amendment(var a): a.instruction = cut(a.instruction); e.payload = .amendment(a)
            case .workerEvent(var w): w.body = cut(w.body); e.payload = .workerEvent(w)
            default: return (e, size)
            }
            log.error("record \(e.id, privacy: .public) over \(hardCap) bytes; sending its head")
        }
        return (e, (try? JSONEncoder().encode(e).count) ?? 0)
    }

    private static func head(_ s: String, _ ratio: Double) -> String {
        utf8Prefix(s, bytes: Int(Double(s.utf8.count) * ratio)) + "\n\n…(truncated; the full text is on the host)"
    }

    private static func event(_ id: String, _ thread: String, _ ts: Int, _ payload: YorozuEvent.Payload) -> YorozuEvent {
        YorozuEvent(id: id, threadId: thread, ts: ts, agentId: "main", payload: payload)
    }

    private static func notice(_ n: Notice) -> NoticeData { NoticeData(code: n.code, params: n.params) }
    private static var now: Int { Int(Date().timeIntervalSince1970 * 1000) }
}

extension ThreadSummary {
    /// The Mac's main chat, the one thread. `lastActivity` is the newest message, epoch ms.
    static func main(_ lastActivity: Double) -> ThreadSummary { ThreadSummary(id: "main", title: "Yorozu", archived: false, lastActivity: lastActivity) }
}
