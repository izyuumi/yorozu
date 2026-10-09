import Foundation
import os
import ProjectXCore
import YorozuWire

/// The v2 Engine behind the relay (docs/ios-relay-contract.md, 0.7): `message`, `sync_request`, `read_state`,
/// `task_control`, `search_request`, `page_request` and the plain `thread_list` in; `receipt`, `admission_status`,
/// `sync_delta`, `task_control_result` and `search_result` out. Records travel by change sequence (`Store.changes`).
/// Messages of the kinds that stay in a job's sub-chat (#319) never reach phones, and the working flag ignores work in
/// job topics (open question 10).
actor EngineBridge: RelayBackend {
    /// The threads this Mac has: one, `main`, holding every v2 message as the Mac's main chat shows them.
    static let threads: Set<String> = ["main"]
    private static let log = Logger(subsystem: "to.yumi.yorozu", category: "relay")

    private let engine: Engine
    private let mode: RuntimeMode
    /// The latest change sequence the live updates reached; nil before the first publish.
    private var published: Int64?
    private var working = false, routing = false
    private var main = ThreadSummary.main(0)
    /// The last 64 `task_control` results, oldest first, for replays of the same `requestId`.
    private var controlled: [TaskControlResultData] = []

    /// Awaited before a phone message reaches the Engine (the model metadata retry, #312).
    private let prepare: @Sendable () async -> Void

    init(engine: Engine, mode: RuntimeMode, prepare: @escaping @Sendable () async -> Void = {}) { self.engine = engine; self.mode = mode; self.prepare = prepare }

    func handle(_ e: YorozuEvent) async -> [YorozuEvent] {
        switch e.payload {
        case .message(let m): return [await admit(m, id: e.id, ts: e.ts)]
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
        default: return []
        }
    }

    /// Called on every poll with the latest snapshot: live updates for the changes past the last published sequence,
    /// or a flag-only one when the working or routing flag moved. The first call only sets the starting point.
    func publish(_ s: Snapshot, to host: RelayHost) async {
        let jobs = Set(((try? await engine.store.jobRecords()) ?? []).map(\.topicID))
        let working = s.work.contains { $0.active && !jobs.contains($0.topicID) }, routing = await engine.routing
        main = .main((s.messages.last(where: \.onMainTimeline)?.created ?? 0) * 1000)
        await host.setMain(main)
        guard let bounds = try? await engine.store.cursorBounds() else { return }
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
                let (events, next, more) = Self.fit(p, thread: "main")
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
        guard id.range(of: #"^[A-Za-z0-9-]{1,64}\z"#, options: .regularExpression) != nil else { return reject("Invalid message id.") }
        guard m.attachments.isEmpty else { return reject("Attachments aren't supported yet.") }
        guard mode.permitsInput(fixtureAcknowledged: false) else { return reject("This Mac is in fixture mode and doesn't take phone messages.") }
        // A resend or a relay replay of something already stored: the receipt is all it needs.
        if await exists(id) { return receipt }
        // Past its deadline (the phone sets send time + 24 h): never routed late, the phone shows Not delivered (#314).
        if let deadline = m.admissionDeadline, deadline < Self.now {
            return .control(.admissionStatus(AdmissionStatusData(eventId: id, status: .expired, reason: "Your Mac was offline for more than 24 hours.")))
        }
        await prepare()
        // Text, id and send time only: no model may learn which device a message came from (#313).
        do { try await engine.send(m.text, id: id, sentAt: Double(ts) / 1000); return receipt }
        catch { return await exists(id) ? receipt : reject(error.localizedDescription) }
    }

    /// Only after a failed send: a keyed lookup of the id.
    private func exists(_ id: String) async -> Bool { ((try? await engine.store.message(id: id)) ?? nil) != nil }

    /// A reply page: the window's changes after the phone's cursor, or the window from its start (`reset`) when the
    /// cursor is absent, zero or stale. Always answered; an unreadable store gives an error page.
    private func reply(_ r: SyncRequestData, thread: String) async -> YorozuEvent {
        let routing = await engine.routing
        guard Self.threads.contains(thread) else { return delta([], thread: thread, after: r.afterSeq.map(Int64.init), routing: routing, error: "Unknown thread.") }
        do {
            let bounds = try await engine.store.cursorBounds()
            let cursor = Int64(r.afterSeq ?? 0)
            let reset = cursor <= 0 || cursor > bounds.latest || bounds.floor.map { cursor < $0 } == true
            let (events, next, more) = Self.fit(try await engine.store.changes(after: reset ? 0 : cursor, limit: 200), thread: thread)
            return delta(events, thread: thread, after: r.afterSeq.map(Int64.init), latest: next, more: more, reset: reset, routing: routing)
        } catch {
            Self.log.error("sync_request unreadable: \(error.localizedDescription, privacy: .public)")
            return delta([], thread: thread, after: r.afterSeq.map(Int64.init), routing: routing, error: "Couldn't read the chat on this Mac: \(error.localizedDescription)")
        }
    }

    /// A page reply: the messages around one message, in or out of the window. It never moves the cursor.
    private func page(_ r: PageRequestData) async -> YorozuEvent {
        let routing = await engine.routing
        guard Self.threads.contains(r.threadId) else { return delta([], thread: r.threadId, routing: routing, requestId: r.requestId, error: "Unknown thread.") }
        do {
            guard let changes = try await engine.store.page(around: r.messageId) else {
                return delta([], thread: r.threadId, routing: routing, requestId: r.requestId, error: "Message not found.")
            }
            let page = delta(changes.filter(Self.sent).map { Self.record($0, thread: r.threadId).event }, thread: r.threadId, routing: routing, requestId: r.requestId)
            // 101 capped records could still pass what 256 chunks carry.
            guard (try? JSONEncoder().encode(page).count).map({ $0 <= Self.hardCap }) == true else {
                return delta([], thread: r.threadId, routing: routing, requestId: r.requestId, error: "That part of the chat is too large to send.")
            }
            return page
        } catch {
            return delta([], thread: r.threadId, routing: routing, requestId: r.requestId, error: "Couldn't read the chat on this Mac: \(error.localizedDescription)")
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
            return .control(.searchResult(SearchResultData(requestId: r.requestId, hits: [], total: 0, error: "Search failed: \(error.localizedDescription)")))
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
    /// Job-only messages are skipped but still consumed, so the cursor passes them (a gap in `seq` is fine).
    private static func fit(_ p: ChangePage, thread: String) -> (events: [YorozuEvent], next: Int64, more: Bool) {
        var events: [YorozuEvent] = [], bytes = 0, used = 0
        for change in p.changes {
            guard sent(change) else { used += 1; continue }
            let r = record(change, thread: thread)
            if !events.isEmpty && (events.count == 200 || bytes + r.size > ChunkData.budget) { break }
            events.append(r.event); bytes += r.size; used += 1
        }
        let more = p.more || used < p.changes.count
        return (events, more ? p.changes[used - 1].seq : p.latest, more)
    }

    /// Everything but messages that stay in a job's sub-chat (#319).
    private static func sent(_ change: Change) -> Bool {
        if case .message(let m) = change.record { return m.onMainTimeline }
        return true
    }

    /// The largest record sent: what 256 chunks carry, less room for the page around it. Worker output has no size
    /// limit, so a bigger record keeps the head of its text and says the rest is on the Mac.
    private static let hardCap = ChunkData.maxCount * ChunkData.slice - 65_536

    private static func record(_ change: Change, thread: String) -> (event: YorozuEvent, size: Int) {
        let seq = Int(change.seq), ms = { (t: Double) in Int(t * 1000) }
        var e: YorozuEvent
        switch change.record {
        case .message(let m):
            e = event(m.id, thread, ms(m.created), .message(MessageData(role: m.role == "user" ? .user : .agent, text: m.body, done: true,
                failed: m.kind == "failure" ? true : nil, kind: m.kind, topicId: m.topicID, taskId: m.taskID, replyTo: m.replyTo,
                notice: m.notice.map(notice), seq: seq,
                readAt: m.role == "user" ? m.readAt.map(ms) : nil, sentAt: m.sentAt.map(ms))))
        case .topic(let t): e = event(t.id, thread, ms(t.created), .topic(TopicData(id: t.id, label: t.label, created: ms(t.created), seq: seq)))
        case .work(let w):
            e = event(w.id, thread, ms(w.created), .task(TaskData(id: w.id, topicId: w.topicID, messageId: w.messageID, instruction: w.instruction,
                executor: w.executor, state: w.state, revision: w.revision, suppressed: w.suppressed, error: w.error, result: w.result,
                created: ms(w.created), seq: seq)))
        case .amendment(let a):
            e = event(a.id, thread, now, .amendment(AmendmentData(id: a.id, taskId: a.taskID, messageId: a.messageID, revision: a.revision,
                                                                  instruction: a.instruction, state: a.state, seq: seq)))
        case .event(let w):
            e = event(w.id, thread, ms(w.created), .workerEvent(WorkerEventData(id: w.id, taskId: w.taskID, kind: w.kind, body: w.body, created: ms(w.created), seq: seq)))
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
        utf8Prefix(s, bytes: Int(Double(s.utf8.count) * ratio)) + "\n\n…(truncated; the full text is on the Mac)"
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
