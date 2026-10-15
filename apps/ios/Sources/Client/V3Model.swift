import Foundation
import Observation
import YorozuWire

/// The v3 client (#425): one pairing with the OpenClaw plugin, the conversations cached on this device, and the link.
/// User messages without `delivered` are the outbox: each new session sends them again, and the plugin drops a
/// `messageId` it already took.
@MainActor @Observable
final class V3Model {
    private(set) var pairing: V3Pairing?
    private(set) var state = V3Connection.State.offline
    private(set) var conversations: [String: Conversation] = [:]
    /// Conversations whose agent is working: from `run_started` or `typing {active}` until `typing {active: false}`,
    /// or 30 s without a repeat.
    private(set) var typing: Set<String> = []
    /// A scanned or pasted code waiting for the user to compare the host fingerprint.
    var pendingPairing: QrPayload?
    /// Why the last pairing attempt failed, for the pairing screen.
    var pairingError: String?

    @ObservationIgnored private var connection: V3Connection?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var typingTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let cache = ConversationCache()

    static let typingTimeout: Duration = .seconds(30)

    init() {
        do {
            pairing = try V3Pairing.load()
        } catch {
            pairingError = String(localized: "Couldn’t read this device’s pairing: \(error.localizedDescription)")
        }
        guard pairing != nil else { return }
        for conversation in cache.loadAll() { conversations[conversation.id] = conversation }
        connect()
    }

    /// Paired, or pairing for the first time.
    var paired: Bool { pairing?.paired == true }
    var connecting: Bool { pairing != nil && !paired }

    /// Newest first.
    var list: [Conversation] {
        conversations.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    var fingerprint: String? { pairing?.pairing.fingerprint }

    // MARK: Pairing

    /// A QR, a pasted string or a tapped link. Returns why it is not a v3 pairing code; otherwise it waits in
    /// ``pendingPairing`` for the fingerprint check.
    func submit(_ text: String) -> String? {
        guard let payload = try? QrPayload.decode(text), payload.v == 3, payload.roomId != nil, payload.secret != nil,
              (Data(base64URLEncoded: payload.macPubkey)?.count ?? 0) == 32 else {
            return String(localized: "This isn’t a Yorozu pairing code. Run `openclaw yorozu pair` on the host and use the code it prints.")
        }
        pairingError = nil
        pendingPairing = payload
        return nil
    }

    /// The user compared the fingerprint: a fresh identity, kept in the Keychain before the first join.
    func confirm(_ payload: QrPayload) {
        pendingPairing = nil
        disconnect()
        cache.wipe()
        conversations = [:]
        let new = V3Pairing(pairing: payload, identity: .generate())
        do {
            try new.save()
        } catch {
            pairingError = String(localized: "Couldn’t save the pairing: \(error.localizedDescription)")
            return
        }
        pairing = new
        connect()
    }

    /// Forgets the host on this device: keys and cache. The plugin keeps the device until `openclaw yorozu devices remove`.
    func unpair() {
        disconnect()
        try? V3Pairing.remove()
        cache.wipe()
        pairing = nil
        conversations = [:]
        typing = []
    }

    // MARK: Link

    private func connect() {
        guard let pairing else { return }
        let local = V3PeerInfo(app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            name: DeviceModel.name)
        guard let connection = try? V3Connection(pairing: pairing.pairing, identity: pairing.identity,
            relayKnows: pairing.relayKnows, local: local) else {
            return failPairing(String(localized: "This pairing code can’t be used."))
        }
        self.connection = connection
        listener = Task { [weak self] in
            let updates = await connection.updates()
            await connection.start()
            for await update in updates { self?.apply(update) }
        }
    }

    private func disconnect() {
        listener?.cancel()
        listener = nil
        if let connection { Task { await connection.stop() } }
        connection = nil
        state = .offline
    }

    /// Back in the foreground: dial now. iOS may have left the socket half open.
    func resume() {
        guard let connection else { return connect() }
        Task { await connection.reconnect() }
    }

    /// iOS suspends a background app: hang up, so the relay does not hold a frozen socket.
    func suspend() {
        guard let connection else { return }
        Task { await connection.stop() }
    }

    private func apply(_ update: V3Connection.Update) {
        switch update {
        case .state(let new):
            state = new
            switch new {
            case .pairingFailed:
                if !paired { failPairing(String(localized: "The host refused this pairing code. It may have expired or been used. Run `openclaw yorozu pair` again.")) }
            case .unpaired:
                if !paired { failPairing(String(localized: "The host doesn’t know this device. Run `openclaw yorozu pair` again.")) }
            case .ready, .offline, .connecting, .hostOffline, .handshaking, .updateRequired:
                break
            }
        case .relayJoined:
            updatePairing { $0.relayKnows = true; $0.pairing.token = "" }
        case .sessionOpen:
            if !paired { updatePairing { $0.paired = true; $0.pairedAt = Date(); $0.pairing.secret = nil } }
            resendOutbox()
        case .accepted(let id):
            mark(id, .sent)
        case .event(let event):
            receive(event)
        }
    }

    private func failPairing(_ message: String) {
        unpair()
        pairingError = message
    }

    private func updatePairing(_ change: (inout V3Pairing) -> Void) {
        guard var pairing else { return }
        change(&pairing)
        self.pairing = pairing
        try? pairing.save()
    }

    // MARK: Messages

    /// A new message in `convId`; a conversation that does not exist yet starts with it ("+" makes the id).
    func send(_ text: String, in convId: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, V3Event.isId(convId) else { return }
        let item = ChatItem(id: V3Event.newId(), kind: .user, text: text, ts: Self.now, status: .queued)
        append(item, to: convId)
        transmit(item, in: convId)
    }

    /// Every user message the plugin has not confirmed, oldest first, on the session that just opened.
    private func resendOutbox() {
        let pending = conversations.values.flatMap { conversation in
            conversation.items.filter { $0.kind == .user && ($0.status ?? .read) < .delivered }.map { (conversation.id, $0) }
        }
        for (convId, item) in pending.sorted(by: { $0.1.ts < $1.1.ts }) { transmit(item, in: convId) }
    }

    private func transmit(_ item: ChatItem, in convId: String) {
        guard let connection else { return }
        let message = V3Message(convId: convId, messageId: item.id, text: item.text)
        Task {
            if await connection.send(message) { self.mark(item.id, .sending, in: convId) }
        }
    }

    private func receive(_ event: V3Event) {
        switch event {
        case .delivered(let ref):
            mark(ref.messageId, .delivered, in: ref.convId)
        case .runStarted(let ref):
            mark(ref.messageId, .read, in: ref.convId)
            setTyping(ref.convId, true)
        case .typing(let t):
            setTyping(t.convId, t.active)
        case .reply(let reply):
            append(ChatItem(id: reply.messageId, kind: .agent, text: reply.text, ts: reply.ts), to: reply.convId)
        case .tool(let tool):
            self.tool(tool)
        case .error(let error):
            guard let convId = error.convId, V3Event.isId(convId) else { return }
            let id = "error:\(error.messageId ?? V3Event.newId())"
            let text = error.code == "run_failed"
                ? String(localized: "The agent run failed: \(error.message)")
                : String(localized: "The host couldn’t handle this: \(error.message)")
            append(ChatItem(id: id, kind: .error, text: text, ts: Self.now), to: convId)
            setTyping(convId, false)
        case .peerInfo, .message, .unknown:
            break
        }
    }

    /// A message's mark only moves forward. `convId` nil: look it up (the relay's `accepted` names no conversation).
    private func mark(_ messageId: String, _ status: SendStatus, in convId: String? = nil) {
        guard let convId = convId ?? conversations.first(where: { $0.value.items.contains { $0.id == messageId } })?.key,
              var conversation = conversations[convId],
              let index = conversation.items.firstIndex(where: { $0.id == messageId && $0.kind == .user }),
              (conversation.items[index].status ?? .queued) < status else { return }
        conversation.items[index].status = status
        store(conversation)
    }

    /// Dedupes by id: a reply seen twice (a resend, two sessions) is one bubble.
    private func append(_ item: ChatItem, to convId: String) {
        guard V3Event.isId(convId) else { return }
        let now = Self.now
        var conversation = conversations[convId] ?? Conversation(id: convId, createdAt: now, updatedAt: now)
        guard !conversation.items.contains(where: { $0.id == item.id }) else { return }
        conversation.items.append(item)
        conversation.updatedAt = now
        store(conversation)
    }

    /// One collapsed row per user message's run, placed when its first call arrives; the last status of a call wins.
    private func tool(_ tool: V3Tool) {
        let id = "tools:\(tool.messageId)"
        var conversation = conversations[tool.convId]
        if conversation?.items.contains(where: { $0.id == id }) != true {
            append(ChatItem(id: id, kind: .tools, text: "", ts: Self.now, tools: []), to: tool.convId)
            conversation = conversations[tool.convId]
        }
        guard var conversation, let index = conversation.items.firstIndex(where: { $0.id == id }) else { return }
        var calls = conversation.items[index].tools ?? []
        if let call = calls.firstIndex(where: { $0.id == tool.callId }) {
            calls[call].status = tool.status
            calls[call].name = tool.name
        } else {
            calls.append(ToolCall(id: tool.callId, name: tool.name, status: tool.status))
        }
        conversation.items[index].tools = calls
        store(conversation)
    }

    private func store(_ conversation: Conversation) {
        conversations[conversation.id] = conversation
        cache.save(conversation)
    }

    private func setTyping(_ convId: String, _ active: Bool) {
        typingTimers[convId]?.cancel()
        typingTimers[convId] = nil
        guard active else {
            typing.remove(convId)
            return
        }
        typing.insert(convId)
        typingTimers[convId] = Task { [weak self] in
            try? await Task.sleep(for: Self.typingTimeout)
            guard !Task.isCancelled else { return }
            self?.typing.remove(convId)
        }
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

extension V3Connection.State {
    /// The list's subtitle.
    var label: String {
        switch self {
        case .ready: String(localized: "Connected")
        case .connecting, .handshaking: String(localized: "Connecting…")
        case .hostOffline: String(localized: "Host offline")
        case .offline: String(localized: "Offline")
        case .updateRequired: String(localized: "Update required")
        case .pairingFailed: String(localized: "Couldn’t pair")
        case .unpaired: String(localized: "Removed from the host")
        }
    }
}
