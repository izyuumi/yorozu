import Foundation
import os
import ProjectXCore
import YorozuWire

/// The v2 Engine behind the relay (docs/ios-relay-contract.md): phone `message`, `sync_request` and
/// `thread_list` in; `receipt`, `admission_status` and `sync_delta` out. One thread, `main`, holding
/// every message of the Mac's main chat, which leaves out the kinds that stay in a job's sub-chat (#319). The
/// working flag ignores work in job topics (open question 10).
actor EngineBridge: RelayBackend {
    private let engine: Engine
    private let mode: RuntimeMode
    /// Message ids of the last published snapshot; nil before the first one.
    private var seen: Set<String>?
    private var working = false

    /// Awaited before a phone message reaches the Engine (the model metadata retry, #312).
    private let prepare: @Sendable () async -> Void

    init(engine: Engine, mode: RuntimeMode, prepare: @escaping @Sendable () async -> Void = {}) { self.engine = engine; self.mode = mode; self.prepare = prepare }

    func handle(_ e: YorozuEvent) async -> [YorozuEvent] {
        switch e.payload {
        case .message(let m): return [await admit(m, id: e.id)]
        case .syncRequest(let r):
            do { return [Self.page(try await mainTimeline(engine.snapshot()), after: r.lastSeen["main"])] }
            catch {
                Logger(subsystem: "to.yumi.yorozu", category: "relay").error("sync_request unanswerable: \(error.localizedDescription, privacy: .public)")
                // 0.6 has no error page. No reply keeps the phone catching up, so live updates cannot move
                // its cursor past the gap, and its next `.paired` asks again.
                return []
            }
        case .threadList:
            guard let s = try? await mainTimeline(engine.snapshot()) else { return [] }
            return [.control(.threadList(ThreadListData(threads: [Self.main(s)])))]
        default: return []
        }
    }

    /// The live update for the poll loop's snapshot: messages the last one lacked, and the working flag
    /// when it changed. Messages are only ever inserted, so ids are all a diff needs.
    func publish(_ s: Snapshot, to host: RelayHost) async {
        let s = await mainTimeline(s)
        let ids = Set(s.messages.map(\.id)), working = s.work.contains { $0.active }
        let previous = seen, wasWorking = self.working
        seen = ids; self.working = working
        guard let previous else { return await host.setMain(Self.main(s)) }
        let new = s.messages.filter { !previous.contains($0.id) }
        guard !new.isEmpty || working != wasWorking else { return }
        if !new.isEmpty { await host.setMain(Self.main(s)) }
        var updates: [YorozuEvent] = [], rest = new[...]
        repeat {
            updates.append(.control(.syncDelta(SyncDeltaData(events: rest.prefix(200).map(Self.event), workingThreadIds: working ? ["main"] : []))))
            rest = rest.dropFirst(200)
        } while !rest.isEmpty
        await host.broadcast(updates)
    }

    private func admit(_ m: MessageData, id: String) async -> YorozuEvent {
        func reject(_ reason: String) -> YorozuEvent { .control(.admissionStatus(AdmissionStatusData(eventId: id, status: .rejected, reason: reason))) }
        let receipt = YorozuEvent.control(.receipt(ReceiptData(eventId: id)))
        guard id.range(of: #"^[A-Za-z0-9-]{1,64}\z"#, options: .regularExpression) != nil else { return reject("Invalid message id.") }
        guard m.attachments.isEmpty else { return reject("Attachments aren't supported yet.") }
        guard mode.permitsInput(fixtureAcknowledged: false) else { return reject("This Mac is in fixture mode and doesn't take phone messages.") }
        // A resend or a relay replay of something already stored: the receipt is all it needs. An id the
        // last poll has not seen yet makes `send` throw on the duplicate key, and the check below answers it.
        if seen?.contains(id) == true { return receipt }
        await prepare()
        // Text and id only: no model may learn which device a message came from (#313).
        do { try await engine.send(m.text, id: id); return receipt }
        catch { return await exists(id) ? receipt : reject(error.localizedDescription) }
    }

    /// The snapshot as phones see it: main-timeline messages only, and no work of job topics (deleted jobs' included).
    private func mainTimeline(_ s: Snapshot) async -> Snapshot {
        let jobs = Set(((try? await engine.store.jobRecords()) ?? []).map(\.topicID))
        var s = s; s.messages.removeAll { !$0.onMainTimeline }; s.work.removeAll { jobs.contains($0.topicID) }
        return s
    }

    /// Only after a failed send: a keyed lookup of the id.
    private func exists(_ id: String) async -> Bool { ((try? await engine.store.message(id: id)) ?? nil) != nil }

    /// A reply page: the messages after `cursor` (all of them when it is absent or unknown), at most 200
    /// events and 512 KB, at least one when any remain.
    private static func page(_ s: Snapshot, after cursor: String?) -> YorozuEvent {
        let start = cursor.flatMap { c in s.messages.firstIndex { $0.id == c } }.map { $0 + 1 } ?? 0
        var events: [YorozuEvent] = [], bytes = 0
        for m in s.messages[start...] {
            let e = event(m), size = (try? JSONEncoder().encode(e).count) ?? 0
            if !events.isEmpty && (events.count == 200 || bytes + size > 512 * 1024) { break }
            events.append(e); bytes += size
        }
        let more = start + events.count < s.messages.count
        return .control(.syncDelta(SyncDeltaData(events: events, threadId: "main", workingThreadIds: s.work.contains { $0.active } ? ["main"] : [], more: more ? true : nil)))
    }

    /// Worker output has no size limit, but one relay frame does (1 MiB, about 16/9 of the event once encrypted and
    /// encoded). Until long results travel in chunks (#313), a phone gets the head of an oversized message.
    private static func phoneText(_ body: String) -> String {
        body.utf8.count <= 256_000 ? body : utf8Prefix(body, bytes: 256_000) + "\n\n…(truncated; full answer on the Mac)"
    }
    private static func event(_ m: Message) -> YorozuEvent {
        YorozuEvent(id: m.id, threadId: "main", ts: Int(m.created * 1000), agentId: "main", syncCursor: m.id,
                    payload: .message(MessageData(role: m.role == "user" ? .user : .agent, text: Self.phoneText(m.body), done: true, failed: m.kind == "failure" ? true : nil)))
    }

    private static func main(_ s: Snapshot) -> ThreadSummary { .main((s.messages.last?.created ?? 0) * 1000) }
}

extension ThreadSummary {
    /// The one thread 0.6.0 has: the Mac's main chat. `lastActivity` is the newest message, epoch ms.
    static func main(_ lastActivity: Double) -> ThreadSummary { ThreadSummary(id: "main", title: "Yorozu", archived: false, lastActivity: lastActivity) }
}
