import Foundation
import YorozuWire

/// The client consumes the same events from a live relay and from the memory-only demo.
protocol ClientTransport: Sendable {
    func updates() async -> AsyncStream<V3Connection.Update>
    func start() async
    func reconnect() async
    func stop() async
    func registerPush(deviceToken: String) async
    @discardableResult func send(_ event: V3Event) async -> Bool
    @discardableResult func send(_ message: V3Message) async -> Bool
}

extension V3Connection: ClientTransport {}

/// Scripted sample data only: no socket, credentials, files or model calls.
actor DemoTransport: ClientTransport {
    private var continuation: AsyncStream<V3Connection.Update>.Continuation?
    private var running = false
    private var replies: [String: Task<Void, Never>] = [:]
    private var pending: [String: (convID: String, task: Task<Void, Never>)] = [:]
    private var histories = DemoData.histories
    private var titles = DemoData.titles
    private var archived: Set<String> = [DemoData.archiveID]
    private var pins: [String: Int64] = [:]
    private var seen: Set<String> = []

    func updates() -> AsyncStream<V3Connection.Update> {
        let (stream, continuation) = AsyncStream<V3Connection.Update>.makeStream()
        self.continuation = continuation
        return stream
    }

    func start() {
        guard !running else { return }
        running = true
        continuation?.yield(.state(.ready))
        continuation?.yield(.sessionOpen(V3PeerInfo(app: "Demo", name: "Demo", capabilities: [V3Devices.capability])))
    }

    func reconnect() { start() }
    func registerPush(deviceToken: String) {}

    func stop() {
        running = false
        for reply in pending.values { reply.task.cancel() }
        pending = [:]
        replies = [:]
        continuation?.yield(.state(.offline))
    }

    func send(_ message: V3Message) -> Bool { send(.message(message)) }

    func send(_ event: V3Event) -> Bool {
        guard running else { return false }
        switch event {
        case .convList:
            emit(.convList(V3ConvList(conversations: histories.map { id, items in
                V3ConvSummary(convId: id, updatedAt: items.last?.ts ?? Self.now, rev: items.last?.seq ?? 0,
                    title: titles[id], archived: archived.contains(id) ? true : nil, pinnedAt: pins[id])
            })))
        case .historyRequest(let request):
            let all = histories[request.convId] ?? []
            let items = all.filter { item in
                (request.after.map { item.seq > $0 } ?? true) && (request.before.map { item.seq < $0 } ?? true)
            }
            emit(.history(V3History(convId: request.convId, before: request.before, after: request.after,
                items: items, more: false, rev: all.last?.seq ?? 0)))
        case .deviceList:
            emit(.deviceList(V3DeviceList(devices: DemoData.devices)))
        case .cronList:
            emit(.cronList(V3CronList(jobs: DemoData.crons)))
        case .readCursor(let cursor):
            emit(.readCursor(cursor))
        case .convPatch(let patch):
            if patch.deleted == true {
                histories[patch.convId] = nil
                titles[patch.convId] = nil
                for reply in pending.values where reply.convID == patch.convId { reply.task.cancel() }
                replies[patch.convId] = nil
            } else {
                if let title = patch.title {
                    titles[patch.convId] = title.isEmpty
                        ? DemoData.titles[patch.convId] ?? histories[patch.convId]?.first(where: { $0.kind == .user })?.text.map { String($0.prefix(60)) }
                        : title
                }
                if let value = patch.archived {
                    if value { archived.insert(patch.convId); pins[patch.convId] = nil } else { archived.remove(patch.convId) }
                }
                if let value = patch.pinned, !archived.contains(patch.convId) { pins[patch.convId] = value ? pins[patch.convId] ?? Self.now : nil }
            }
            emit(.convUpdate(V3ConvUpdate(convId: patch.convId, title: titles[patch.convId],
                archived: archived.contains(patch.convId) ? true : nil, pinnedAt: pins[patch.convId], deleted: patch.deleted)))
        case .message(let message):
            guard seen.insert(message.messageId).inserted else { return true }
            append(.user, id: message.messageId, text: message.text, to: message.convId)
            if titles[message.convId] == nil {
                titles[message.convId] = String(message.text.prefix(60))
                emit(.convUpdate(V3ConvUpdate(convId: message.convId, title: titles[message.convId], pinnedAt: pins[message.convId])))
            }
            // Each conversation answers in order, even if several messages are sent quickly.
            let previous = replies[message.convId]
            let task = Task { [weak self] in
                await previous?.value
                if !Task.isCancelled { await self?.answer(message) }
                await self?.finished(message.messageId)
            }
            replies[message.convId] = task
            pending[message.messageId] = (message.convId, task)
        default: break
        }
        return true
    }

    private func finished(_ messageID: String) { pending[messageID] = nil }

    private func answer(_ message: V3Message) async {
        continuation?.yield(.accepted(messageId: message.messageId))
        guard await pause(.milliseconds(180)) else { return }
        let ref = V3MessageRef(convId: message.convId, messageId: message.messageId)
        emit(.delivered(ref))
        guard await pause(.milliseconds(250)) else { return }
        emit(.runStarted(ref))
        let reset = ["/new", "/reset"].contains(message.text.lowercased())
        let callID = "demo-\(message.messageId)"
        if !reset {
            emit(.tool(V3Tool(convId: message.convId, messageId: message.messageId, callId: callID,
                name: "demo_sample", status: .running)))
        }
        guard await pause(.milliseconds(850)) else { return }
        if reset {
            append(.reset, id: V3Event.newId(), text: nil, to: message.convId)
            emit(.history(V3History(convId: message.convId, items: histories[message.convId] ?? [],
                more: false, rev: histories[message.convId]?.last?.seq ?? 0)))
        } else {
            emit(.tool(V3Tool(convId: message.convId, messageId: message.messageId, callId: callID,
                name: "demo_sample", status: .done)))
        }
        let text = reset ? DemoData.resetReply
            : DemoData.reply(to: message.text)
        let id = V3Event.newId()
        append(.agent, id: id, text: text, to: message.convId)
        emit(.reply(V3Reply(convId: message.convId, messageId: id, text: text, ts: Self.now)))
        emit(.typing(V3Typing(convId: message.convId, active: false)))
    }

    private func pause(_ duration: Duration) async -> Bool {
        do { try await Task.sleep(for: duration) } catch { return false }
        return running && !Task.isCancelled
    }

    private func append(_ kind: V3HistoryItem.Kind, id: String, text: String?, to convID: String) {
        var items = histories[convID] ?? []
        items.append(V3HistoryItem(kind: kind, id: id, seq: (items.last?.seq ?? 0) + 1, ts: Self.now, text: text))
        histories[convID] = items
    }

    private func emit(_ event: V3Event) { continuation?.yield(.event(event)) }
    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}
