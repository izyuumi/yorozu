import Foundation
import YorozuShared

/// Simulators have no camera, so the end-to-end harness injects the QR payload (and a first
/// message) as `-name value` launch arguments. Read straight from `ProcessInfo`: the
/// `UserDefaults` argument domain tries to property-list-parse the value first, and a JSON
/// payload is not a plist.
private func launchArgument(_ name: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-\(name)"), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

extension ThreadSummary {
    /// The thread that always exists, so the list is never empty — not even before pairing.
    static let home = ThreadSummary(id: "home", title: "Home", archived: false, pinned: true)
}

/// Every thread the phone knows about: the relay connection, the messages per thread, and
/// whether the Mac is up. History is read from the encrypted local cache first, so the app
/// opens and reads offline; the Mac's `sync_delta` fills in whatever happened since.
@MainActor
@Observable
final class ChatModel {
    private(set) var stored: PairingStore.Stored?
    private(set) var threads: [ThreadSummary] = [.home]
    /// Messages per thread id, oldest first.
    private(set) var events: [String: [YorozuEvent]] = [:]
    private(set) var state: RelayClient.State = .connecting
    /// Starts pessimistic: the relay tells us the truth in its `joined` reply.
    private(set) var ownerOnline = false
    private(set) var failure: String?
    /// Action IDs already answered from this device, so the card stops offering buttons.
    private(set) var answered: Set<String> = []
    /// One composer draft per thread, so switching threads does not lose what was typed.
    var drafts: [String: String] = [:]

    private var client: RelayClient?
    private let cache = CacheStore.open()

    private let autoSend = launchArgument("yorozuSend")
    private let autoThread = launchArgument("yorozuThread")
    private var autoSent: Set<String> = []

    var isPaired: Bool { stored != nil }

    init() {
        if let injected = launchArgument("yorozuPair") {
            // Surface the reason rather than silently falling back to the scanner.
            do { try pair(with: injected) } catch { failure = error.localizedDescription }
        } else {
            stored = PairingStore.load()
        }
        let cached = cache.threads()
        if !cached.isEmpty { threads = cached }
        for thread in threads { events[thread.id] = cache.events(threadId: thread.id) }
        trace("paired=\(isPaired) threads=\(threads.count) failure=\(failure ?? "none")")
    }

    /// Only speaks when the harness is driving; see ``launchArgument``.
    private func trace(_ line: String) {
        guard autoSend != nil else { return }
        print("YOROZU-E2E \(line)")
    }

    /// Accepts an untrusted QR string, persists it with a fresh device identity, and connects.
    func pair(with text: String) throws {
        let stored = PairingStore.Stored(
            pairing: try QrPayload.decode(text),
            identity: .generate()
        )
        try PairingStore.save(stored)
        self.stored = stored
    }

    func unpair() {
        PairingStore.clear()
        CacheStore.clear()
        client = nil
        stored = nil
        threads = [.home]
        events = [:]
    }

    func start() {
        guard let stored, client == nil else { return }
        do {
            let client = try RelayClient(pairing: stored.pairing, identity: stored.identity)
            self.client = client
            Task { [weak self] in
                for await update in await client.connect() { self?.apply(update) }
            }
        } catch {
            failure = error.localizedDescription
            trace("connect failed: \(error)")
        }
    }

    func send(in thread: ThreadSummary) {
        let text = (drafts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        drafts[thread.id] = ""
        send(text, in: thread.id)
    }

    func createThread(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The Mac mints the id and answers every device with the new list.
        emit(.threadCreate(ThreadCreateData(title: trimmed.isEmpty ? nil : trimmed)), in: ThreadSummary.home.id)
    }

    func archive(_ thread: ThreadSummary) {
        guard !thread.pinned else { return }
        // Optimistic: the Mac's `thread_list` is what finally decides.
        threads.removeAll { $0.id == thread.id }
        emit(.threadArchive(ThreadArchiveData()), in: thread.id)
    }

    private func send(_ text: String, in threadId: String) {
        let event = YorozuEvent(
            id: UUID().uuidString,
            threadId: threadId,
            ts: Int(Date().timeIntervalSince1970 * 1000),
            agentId: "phone",
            payload: .message(MessageData(role: .user, text: text))
        )
        upsert(event)
        emit(event)
    }

    private func emit(_ payload: YorozuEvent.Payload, in threadId: String) {
        emit(
            YorozuEvent(
                id: UUID().uuidString,
                threadId: threadId,
                ts: Int(Date().timeIntervalSince1970 * 1000),
                agentId: "phone",
                payload: payload
            )
        )
    }

    private func emit(_ event: YorozuEvent) {
        guard let client else { return }
        Task { try? await client.send(event) }
    }

    /// Answers a pending approval card, in the thread the card was raised in. `Discuss` is
    /// answered too: the runtime keeps the action pending and sends a fresh card, with a new
    /// action ID, after it has explained itself.
    func answer(_ actionId: String, in threadId: String, _ answer: ApprovalAnswerData.Answer) {
        answered.insert(actionId)
        emit(.approvalAnswer(ApprovalAnswerData(actionId: actionId, answer: answer)), in: threadId)
    }

    /// Asks for everything each thread has gained since the last event we hold.
    private func requestSync() {
        emit(
            .syncRequest(SyncRequestData(lastSeen: events.compactMapValues { $0.last?.id })),
            in: ThreadSummary.home.id
        )
    }

    private func apply(_ update: RelayClient.Update) {
        switch update {
        case .state(let state):
            self.state = state
            trace("state=\(state.rawValue)")
            if state == .paired {
                failure = nil
                requestSync()
                if let autoThread { createThread(title: autoThread) }
                if let autoSend { send(autoSend, in: ThreadSummary.home.id) }
            }
        case .ownerOnline(let online):
            ownerOnline = online
            trace("ownerOnline=\(online)")
        case .event(let event):
            switch event.payload {
            case .threadList(let data):
                threads = data.threads.filter { !$0.archived }
                cache.save(threads: threads)
                autoSendToNewThread()
            case .syncDelta(let data):
                for event in data.events { upsert(event) }
            default:
                upsert(event)
            }
        case .failed(let reason):
            failure = reason
            trace("failed: \(reason)")
        }
    }

    /// Every kind is kept, per thread, in arrival order: the thread draws the messages and the
    /// approval cards, and the thoughts, tool calls and results behind them are what the
    /// drill-down traces. It is also what the encrypted cache holds, so a relaunch redraws the
    /// same thread offline.
    ///
    /// Agent replies stream as repeated events under one id, each carrying the whole text so
    /// far, so the newest wins in place instead of appending a duplicate bubble.
    private func upsert(_ event: YorozuEvent) {
        var thread = events[event.threadId] ?? []
        if let index = thread.firstIndex(where: { $0.id == event.id }) {
            thread[index] = event
        } else {
            thread.append(event)
        }
        events[event.threadId] = thread
        cache.save(events: thread, threadId: event.threadId)

        // The harness reads these off `simctl launch --console-pty`.
        guard autoSend != nil else { return }
        switch event.payload {
        case .message(let data) where data.role == .agent:
            print("YOROZU-E2E-REPLY [\(title(of: event.threadId))] \(data.text)")
        case .toolCall(let data):
            print("YOROZU-E2E-TOOL \(data.name)")
        default:
            break
        }
    }

    private func title(of threadId: String) -> String {
        threads.first { $0.id == threadId }?.title ?? threadId
    }

    /// Harness only: once the thread it asked for exists, send the same first message there.
    private func autoSendToNewThread() {
        guard let autoSend, let autoThread,
            let thread = threads.first(where: { $0.title == autoThread }),
            !autoSent.contains(thread.id)
        else { return }
        autoSent.insert(thread.id)
        send(autoSend, in: thread.id)
    }
}
