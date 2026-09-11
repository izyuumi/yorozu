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

/// One thread's worth of state: the relay connection, the messages, and whether the Mac is up.
/// Threads (the "Threads" ticket) will generalise `threadId` away.
@MainActor
@Observable
final class ChatModel {
    static let threadId = "home"

    private(set) var stored: PairingStore.Stored?
    private(set) var events: [YorozuEvent] = []
    private(set) var state: RelayClient.State = .connecting
    /// Starts pessimistic: the relay tells us the truth in its `joined` reply.
    private(set) var ownerOnline = false
    private(set) var failure: String?
    /// Action IDs already answered from this device, so the card stops offering buttons.
    private(set) var answered: Set<String> = []
    var draft = ""

    private var client: RelayClient?

    private let autoSend = launchArgument("yorozuSend")

    var isPaired: Bool { stored != nil }

    init() {
        if let injected = launchArgument("yorozuPair") {
            // Surface the reason rather than silently falling back to the scanner.
            do { try pair(with: injected) } catch { failure = error.localizedDescription }
        } else {
            stored = PairingStore.load()
        }
        trace("paired=\(isPaired) failure=\(failure ?? "none")")
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
        client = nil
        stored = nil
        events = []
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

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }

    private func send(_ text: String) {
        guard let client else { return }
        let event = YorozuEvent(
            id: UUID().uuidString,
            threadId: Self.threadId,
            ts: Int(Date().timeIntervalSince1970 * 1000),
            agentId: "phone",
            payload: .message(MessageData(role: .user, text: text))
        )
        upsert(event)
        Task { try? await client.send(event) }
    }

    /// Answers a pending approval card. `Discuss` is answered too: the runtime keeps the
    /// action pending and sends a fresh card, with a new action ID, after it has explained.
    func answer(_ actionId: String, _ answer: ApprovalAnswerData.Answer) {
        guard let client else { return }
        answered.insert(actionId)
        let event = YorozuEvent(
            id: UUID().uuidString,
            threadId: Self.threadId,
            ts: Int(Date().timeIntervalSince1970 * 1000),
            agentId: "phone",
            payload: .approvalAnswer(ApprovalAnswerData(actionId: actionId, answer: answer))
        )
        Task { try? await client.send(event) }
    }

    private func apply(_ update: RelayClient.Update) {
        switch update {
        case .state(let state):
            self.state = state
            trace("state=\(state.rawValue)")
            if state == .paired {
                failure = nil
                if let autoSend { send(autoSend) }
            }
        case .ownerOnline(let online):
            ownerOnline = online
            trace("ownerOnline=\(online)")
        case .event(let event):
            upsert(event)
        case .failed(let reason):
            failure = reason
            trace("failed: \(reason)")
        }
    }

    /// Every kind is kept, in arrival order: the thread draws the messages, and the thoughts,
    /// tool calls and results behind them are what the drill-down traces.
    ///
    /// Agent replies stream as repeated events under one id, each carrying the whole text so
    /// far, so the newest wins in place instead of appending a duplicate bubble.
    private func upsert(_ event: YorozuEvent) {
        guard event.threadId == Self.threadId else { return }
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
        // The harness reads these off `simctl launch --console-pty`.
        guard autoSend != nil else { return }
        switch event.payload {
        case .message(let data) where data.role == .agent:
            print("YOROZU-E2E-REPLY \(data.text)")
        case .toolCall(let data):
            print("YOROZU-E2E-TOOL \(data.name)")
        default:
            break
        }
    }
}
