import Foundation
import Observation
import YorozuWire

/// The phone's half of docs/ios-v0.6.0-contract.md: the one pairing, the `RelayClient` it drives,
/// and the one conversation (`main`) as bubbles. Sends `message` and `sync_request`; reads
/// `receipt`, `admission_status` and `sync_delta`; ignores everything else.
@MainActor
@Observable
final class PhoneModel {
    struct Bubble: Identifiable, Equatable {
        let id: String
        let user: Bool
        var text: String
        var failed = false
        /// Why the Mac refused a message, shown under it as is.
        var reason: String?
    }

    /// A scanned, pasted or tapped code, held until the user has seen its relay and Mac key.
    struct PendingPairing: Identifiable {
        let id = UUID()
        let payload: QrPayload
        /// The Mac this phone is already paired with: a repair rather than a new Mac.
        let repair: Bool

        var relayHost: String { URLComponents(string: payload.relayUrl)?.host ?? payload.relayUrl }
        /// The Mac key's first 8 bytes as hex, to compare with the Mac's screen.
        var fingerprint: String {
            (Data(base64URLEncoded: payload.macPubkey) ?? Data()).prefix(8)
                .map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }

    var draft = ""
    var pendingPairing: PendingPairing?
    private(set) var bubbles: [Bubble] = []
    /// The Mac has a turn running: `sync_delta.workingThreadIds` contains `main`.
    private(set) var working = false
    private(set) var sending = false
    /// The relay has accepted this phone, so the chat shows rather than the pairing screen.
    private(set) var linked = false
    private(set) var state: TransportState = .closed
    private(set) var ownerOnline = false
    /// The link's failure; cleared by the next `.paired`.
    private(set) var failure: String?
    /// Why the last send did not go; the draft is still in the composer.
    private(set) var sendError: String?
    private(set) var hostName: String?

    private var pairing: QrPayload?
    private var relay: RelayClient?
    private var listener: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    /// Messages without a `receipt` or `admission_status` yet, resent on every `.paired`. The Mac
    /// dedupes by id, so a resend is never a second message.
    private var unreceipted: [YorozuEvent] = []
    /// `syncCursor` of the newest message held without a gap.
    private var cursor: String?
    private var catchingUp = false

    var hasPairing: Bool { pairing != nil }
    var status: ClientConnectionStatus { ClientConnectionStatus(state: state, ownerOnline: ownerOnline, failure: failure) }
    var canSend: Bool { state == .paired && !sending }

    /// Loads the pairing; the first `resume()` dials.
    init() {
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

    /// Replaces the pairing with a fresh identity for the confirmed code, and dials it.
    func confirm(_ pending: PendingPairing) {
        pendingPairing = nil
        let stored = PairingStore.Stored(pairing: pending.payload, identity: .generate())
        do { try PairingStore.save(stored) } catch {
            failure = error.localizedDescription
            return
        }
        disconnect()
        connect(stored)
        start()
    }

    func remove() {
        do { try PairingStore.remove() } catch {
            failure = error.localizedDescription
            return
        }
        disconnect()
    }

    private func connect(_ stored: PairingStore.Stored) {
        let identity = stored.identity.sessionPublicKey
        do {
            relay = try RelayClient(
                pairing: stored.pairing, identity: stored.identity, paired: stored.paired == true,
                counters: PairingCounterStorage(ownPublicKey: identity),
                onPaired: { PairingStore.markPaired(expectedIdentity: identity) })
        } catch {
            failure = error.localizedDescription
            return
        }
        pairing = stored.pairing
        linked = stored.paired == true
    }

    private func disconnect() {
        suspend()
        relay = nil
        pairing = nil
        linked = false
        bubbles = []
        unreceipted = []
        cursor = nil
        catchingUp = false
        failure = nil
        sendError = nil
        hostName = nil
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
        working = false
    }

    /// Back in the foreground: dial, or redial now instead of waiting out a backoff.
    func resume() {
        guard listener != nil else { return start() }
        Task { [relay] in await relay?.reconnect() }
    }

    private func apply(_ update: TransportUpdate) {
        switch update {
        case .state(let state):
            self.state = state
            if state != .paired {
                ownerOnline = false
                working = false
            }
            if state == .joined || state == .paired { linked = true }
            if state == .paired { paired() }
        case .ownerOnline(let online):
            ownerOnline = online
        case .peerInfo(let info):
            hostName = info.computerName
        case .compatibility:
            break // An incompatible host also arrives as `.failed("Update required: …")`.
        case .failed(let reason):
            failure = reason
        case .event(let event):
            receive(event)
        }
    }

    /// The relay never buffers Mac -> phone frames, so every `.paired` catches up and resends.
    private func paired() {
        failure = nil
        catchingUp = true
        let events = [syncRequest()] + unreceipted
        Task { [relay] in
            for event in events { try? await relay?.send(event) }
        }
    }

    // MARK: Messages

    /// The draft stays in the composer until the relay has taken the message.
    func send() async {
        let text = draft
        guard let relay, canSend else { return }
        sending = true
        defer { sending = false }
        let event = YorozuEvent(id: UUID().uuidString, threadId: "main", ts: Self.now, agentId: "device",
                                payload: .message(MessageData(role: .user, text: text)))
        unreceipted.append(event)
        do {
            try await relay.send(event)
        } catch {
            unreceipted.removeAll { $0.id == event.id }
            sendError = error.localizedDescription
            return
        }
        sendError = nil
        merge(Bubble(id: event.id, user: true, text: text))
        if draft == text { draft = "" }
    }

    private func receive(_ event: YorozuEvent) {
        switch event.payload {
        case .receipt(let receipt):
            unreceipted.removeAll { $0.id == receipt.eventId }
        case .admissionStatus(let status) where status.status == .rejected:
            unreceipted.removeAll { $0.id == status.eventId }
            if let index = bubbles.firstIndex(where: { $0.id == status.eventId }) {
                bubbles[index].failed = true
                bubbles[index].reason = status.reason
            }
        case .syncDelta(let delta):
            for event in delta.events {
                guard case .message(let message) = event.payload else { continue }
                merge(Bubble(id: event.id, user: message.role == .user, text: message.text, failed: message.failed == true))
            }
            working = delta.workingThreadIds?.contains("main") == true
            let last = delta.events.last?.syncCursor
            if delta.threadId == "main" {
                // A reply page: older pages are all in, so the cursor moves.
                if let last { cursor = last }
                if delta.more == true {
                    let next = syncRequest()
                    Task { [relay] in try? await relay?.send(next) }
                } else {
                    catchingUp = false
                }
            } else if !catchingUp, let last {
                // A live update; while catching up, older pages may still be missing.
                cursor = last
            }
        default:
            break
        }
    }

    /// v2 messages never change once stored, so the stored copy replaces the sent bubble in place.
    private func merge(_ bubble: Bubble) {
        if let index = bubbles.firstIndex(where: { $0.id == bubble.id }) {
            bubbles[index] = bubble
        } else {
            bubbles.append(bubble)
        }
    }

    private func syncRequest() -> YorozuEvent {
        YorozuEvent(id: UUID().uuidString, threadId: "main", ts: Self.now, agentId: "device",
                    payload: .syncRequest(SyncRequestData(lastSeen: cursor.map { ["main": $0] } ?? [:], threadId: "main")))
    }

    private static var now: Int { Int(Date().timeIntervalSince1970 * 1000) }
}
