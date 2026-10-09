import CryptoKit
import Foundation
import Network
import os

/// Long-lived device identity for a paired phone: the Ed25519 key the relay checks on every
/// frame, and the X25519 key the session key is agreed from. Stored as JSON by the caller
/// (the iOS app keeps it in the Keychain); `Data` codes as base64.
public struct PhoneIdentity: Codable, Equatable, Sendable {
    public var signingPrivateKey: Data
    public var signingPublicKey: Data
    public var sessionPrivateKey: Data
    public var sessionPublicKey: Data

    public init(
        signingPrivateKey: Data,
        signingPublicKey: Data,
        sessionPrivateKey: Data,
        sessionPublicKey: Data
    ) {
        self.signingPrivateKey = signingPrivateKey
        self.signingPublicKey = signingPublicKey
        self.sessionPrivateKey = sessionPrivateKey
        self.sessionPublicKey = sessionPublicKey
    }

    public static func generate() -> PhoneIdentity {
        let signing = YorozuCrypto.generateSigningKeypair()
        let session = YorozuCrypto.generateKeypair()
        return PhoneIdentity(
            signingPrivateKey: signing.privateKey,
            signingPublicKey: signing.publicKey,
            sessionPrivateKey: session.privateKey,
            sessionPublicKey: session.publicKey
        )
    }
}

/// Frame bodies, base64url JSON inside the relay's opaque `payload`. `hello` is the phone
/// announcing its X25519 key; everything after it is sealed. Mirrors `FrameBody` in
/// packages/runtime/src/serve.ts.
private struct FrameBody: Codable {
    var t: String
    /// `hello`: phone X25519 public key, base64url.
    var pub: String?
    /// `hello`: phone Ed25519 public key, the one the relay knows this device by. The Mac keeps
    /// it so "remove this device" can be addressed to the relay as well as to itself.
    var spub: String?
    /// `hello`, first time only: ``YorozuCrypto/helloProof`` over the QR's secret and both keys,
    /// which is what tells the Mac these keys came from a phone that read its screen and not
    /// from the relay.
    var proof: String?
    /// `box`: nonce and ciphertext, base64url.
    var n: String?
    var c: String?
}

/// The relay's own control messages. Only the envelope is ours; `payload` stays opaque to it.
private struct Inbound: Decodable {
    var type: String
    var nonce: String?
    var payload: String?
    var ownerOnline: Bool?
    var online: Bool?
    var flowControl: Bool?
    var flowBytes: Int?
    /// `accepted`: the signature of the frame the relay took, and whether it was buffered.
    var sig: String?
    var buffered: Bool?
}


/// One socket of the session and what it has learned in phase 1 (socket, join, `joined`). Touched only on
/// the ``RelayClient`` actor; `@unchecked Sendable` so the socket callbacks can hold it weakly.
private final class Leg: @unchecked Sendable {
    enum Route: Equatable { case relay, direct(DirectCandidate) }

    let route: Route
    let socket: any LegSocket
    /// The relay's connect challenge, or the nonce in the Mac's direct `joined`.
    var nonce = ""
    /// Direct: the nonce this phone sent in `probe`, which the Mac's `joined` signs.
    var phoneNonce = ""
    var joined = false
    /// Direct: the Mac's Ed25519 key from a verified `joined`; frames are checked against it.
    var macKey: Data?
    /// Relay `joined`: whether the Mac held a socket, and whether the relay wants flow acks.
    var ownerOnline = false
    var flowControl = false
    /// Frame signature -> event ID for this socket's sent events, so the relay's `accepted` reply can
    /// be matched to its event.
    var sentSigs: [String: String] = [:]
    /// Direct: iOS said Local Network access is withheld while this socket waited.
    var localNetworkDenied = false
    /// Phase 1's deadline: `joined` within it, or the leg fails.
    var deadline: Task<Void, Never>?

    init(route: Route, socket: any LegSocket) {
        self.route = route
        self.socket = socket
    }

    var candidate: DirectCandidate? {
        if case .direct(let candidate) = route { candidate } else { nil }
    }
}

/// Phone side of docs/ios-relay-contract.md: one session object over two kinds of socket — the blind relay
/// (`URLSessionWebSocketTask`) and, when the user turned it on, the Mac's own direct listener on its LAN or
/// VPN addresses (`NWConnection`, "Direct path"). One ``ChannelCounter`` serves both, so a path switch can
/// never reuse a `seq`.
///
/// Each dial is a race: direct candidates at once, the relay about 300 ms later, and the first leg to an
/// authenticated `joined` carries the session; phase 2 (`hello`, the peer-info exchange) runs on it alone.
/// A direct leg that authenticates while the session is on the relay takes it over (make-before-break):
/// `hello` on the direct socket, then the relay closes. A healthy direct session is never given up for the
/// relay; a failed one hands over at once, and its candidate backs off 30 s, doubling to 10 minutes.
/// Every path switch is a new session: `.joined`, `.paired`, and the caller catches up and resends.
///
/// The relay token is spent exactly once — after the first accepted join the relay knows this device,
/// and every later join answers the connect nonce instead — and ``connect()`` keeps re-dialling with a
/// capped backoff until ``close()``.
public actor RelayClient: ChatTransport {
    /// Spelled as nested names because this client predates ``ChatTransport`` and its callers
    /// already say `RelayClient.State`. `ownerOnline` is the relay's view of whether the room's
    /// Mac holds a live socket: frames sent while it is false are buffered and drained later.
    public typealias State = TransportState
    public typealias Update = TransportUpdate

    private let pairing: QrPayload
    private let identity: PhoneIdentity
    private let session: URLSession
    private let dial: URL
    /// `send` is device->mac, `recv` mac->device; see ``YorozuCrypto/deriveChannelKeys``.
    private let channelKeys: (send: SymmetricKey, recv: SymmetricKey)
    /// Older Mac runtimes sealed plain events with one key in both directions.
    private let legacyKey: SymmetricKey
    private enum ChannelFormat { case current, legacy }
    private var channelFormat: ChannelFormat?
    public private(set) var compatibility: PeerCompatibility = .legacy
    public private(set) var peerInfo: PeerInfoData?
    private let localPeer: PeerInfoData
    private(set) var peerInfoRequestID: String?
    private var ready = false
    private var incompatible = false
    private var peerExchange: Task<Void, Never>?
    /// Where each direction stands, persisted before every send and after every accept so a
    /// relaunch can neither reuse a `seq` nor accept one it already saw.
    private var counter: ChannelCounter
    private let counterStore: any ChannelCounterStorage
    private let logger = Logger(subsystem: "to.yumi.yorozu", category: "relay")
    private var updates: AsyncStream<Update>.Continuation?

    /// Where this device can be woken, kept so every relay join can say it again.
    private var deviceToken: String?
    /// The relay has not heard `deviceToken` yet. A direct session (#315) never joins the relay, so it opens
    /// one relay socket only to say `push`, then hangs it up.
    private var pushOwed = false
    private var pushLeg: Leg?
    private let onPushSent: (@Sendable (String) -> Void)?

    /// The leg the session runs on; set at its `joined`.
    private var current: Leg?
    /// Legs still in phase 1. Once the session is on the relay, direct legs here are upgrade attempts.
    private var racing: [Leg] = []
    /// Starts the relay leg 300 ms into a race that has direct candidates.
    private var stagger: Task<Void, Never>?
    /// The backoff before the next race.
    private var retry: Task<Void, Never>?
    /// The next direct attempt while the session is on the relay and every candidate is backing off.
    private var upgradeTimer: Task<Void, Never>?
    /// True once the relay has accepted this device, so later joins need no token. Seeded by
    /// the caller from whatever it persisted, and `onPaired` is how it learns to persist it.
    private var paired: Bool
    /// The relay refused the pairing code as unknown: it may have spent it on this very device
    /// on a socket lost before `joined` arrived, so joins prove the device as a known one.
    private var codeSpent = false
    private let onPaired: (@Sendable () -> Void)?
    private var lastFlowAckBytes = 0
    private var flowFramesSinceAck = 0
    /// Cleared by ``connect()``, set by ``close()``: nothing dials while it is set.
    private var stopped = true
    private var attempt = 0
    private var pinger: Task<Void, Never>?
    private var pongDeadline: Task<Void, Never>?
    private var phaseDeadline: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// The interfaces of the last path seen; nil until the monitor's first report.
    private var pathSignature: String?
    /// LAN candidates only with Wi-Fi or Ethernet up; VPN candidates only with an `.other` interface up.
    private var lanUsable = false
    private var vpnUsable = false

    private var directEnabled: Bool
    private var candidates: [DirectCandidate]
    private var backoff: [DirectCandidate: (failures: Int, until: ContinuousClock.Instant)] = [:]
    /// Candidates iOS refused Local Network access for, skipped until the next foreground or toggle.
    private var denied: Set<DirectCandidate> = []
    private var report = DirectReport()

    /// Throws if the QR payload is not usable — a bad relay URL, a missing room, or a Mac
    /// public key the channel keys cannot be agreed from — or if `counters` holds something it
    /// cannot read: a counter that starts over is a channel the Mac drops every box from, and
    /// that is better said now than discovered as a chat that never answers.
    ///
    /// - Parameters:
    ///   - paired: whether the relay already knows this device, so the one-time token in
    ///     `pairing` has been spent and must not be sent again.
    ///   - session: the URLSession the relay socket is dialled on.
    ///   - counters: where the sequence counters for this pairing are kept across relaunches.
    ///     The apps pass storage that keeps them in the pairing record next to the identity;
    ///     nil falls back to `UserDefaults.standard`, which an iOS reinstall does not keep.
    ///   - direct: whether the user turned the direct path on.
    ///   - candidates: the direct addresses the Mac last advertised, as the caller stored them.
    ///   - onPaired: called once, the first time the relay accepts this device, so the caller
    ///     can persist that fact. Called off the main actor.
    ///   - onPushSent: called with the device token each time it was said to the relay, off the main actor.
    public init(
        pairing: QrPayload,
        identity: PhoneIdentity,
        paired: Bool = false,
        session: URLSession = .shared,
        counters: (any ChannelCounterStorage)? = nil,
        direct: Bool = false,
        candidates: [DirectCandidate] = [],
        deviceName: String? = nil,
        onPaired: (@Sendable () -> Void)? = nil,
        onPushSent: (@Sendable (String) -> Void)? = nil
    ) throws {
        guard let url = URL(string: pairing.relayUrl), url.scheme?.hasPrefix("ws") == true else {
            throw YorozuCrypto.CryptoError.malformed(String(localized: "relay URL is not a websocket URL"))
        }
        guard let room = pairing.roomId else {
            throw YorozuCrypto.CryptoError.malformed(String(localized: "QR payload carries no room ID"))
        }
        // The room ID is only carried in `join`, which is too late for a relay that has to
        // route the socket before reading it, so it also goes in the URL. Relays that route
        // on the message instead simply ignore the query.
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw YorozuCrypto.CryptoError.malformed(String(localized: "relay URL is not a websocket URL"))
        }
        components.queryItems =
            (components.queryItems ?? []) + [URLQueryItem(name: "room", value: room)]
        guard let dial = components.url else {
            throw YorozuCrypto.CryptoError.malformed(String(localized: "relay URL is not a websocket URL"))
        }
        guard let macPub = Data(base64URLEncoded: pairing.macPubkey) else {
            throw YorozuCrypto.CryptoError.malformed(String(localized: "Mac public key is not base64url"))
        }
        self.pairing = pairing
        self.identity = identity
        self.session = session
        self.dial = dial
        self.paired = paired
        self.onPaired = onPaired
        self.onPushSent = onPushSent
        self.directEnabled = direct
        self.candidates = Array(candidates.filter(\.isValid).prefix(DirectCandidate.maxCount))
        // The phone's model name rides in the claim's `computerName`; one that would fail validation is left out.
        var peer = PeerInfoData.local
        peer.computerName = deviceName
        if !peer.isValid { peer.computerName = nil }
        self.localPeer = peer
        self.channelKeys = try YorozuCrypto.deriveChannelKeys(
            myPriv: identity.sessionPrivateKey,
            theirPub: macPub,
            role: .device
        )
        self.legacyKey = try YorozuCrypto.deriveSessionKey(
            myPriv: identity.sessionPrivateKey,
            theirPub: macPub
        )
        self.counterStore = counters ?? ChannelCounterStore(
            defaults: .standard,
            ownPub: identity.sessionPublicKey,
            peerPub: macPub
        )
        self.counter = try counterStore.load() ?? ChannelCounter()
    }

    deinit { pathMonitor?.cancel() }

    // MARK: Lifecycle

    /// Dials, and keeps re-dialling after every drop, yielding every update until ``close()``.
    /// Calling it twice replaces the previous stream's continuation, so treat it as one-shot
    /// per client.
    public func connect() -> AsyncStream<Update> {
        let stream = makeUpdateStream()
        // A client that was closed can be dialled again. The phone does exactly this: a
        // background drain hangs up so the OS can suspend it, and the next foreground connects
        // afresh rather than being left with a client that will never redial.
        dropAll()
        stopped = false
        attempt = 0
        updates?.yield(.direct(report))
        // The first race waits for the monitor's first report, so direct candidates are gated on a known path.
        if pathMonitor == nil { watchNetworkPath() } else if pathSignature != nil { race() }
        return stream
    }

    /// The receive stream is separate from dialing so encrypted-wire conformance can exercise
    /// the real receive boundary without depending on a live network socket.
    func makeUpdateStream() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        updates = continuation
        return stream
    }

    /// Dials again now instead of waiting out the backoff — the app came back to the
    /// foreground, where a socket dropped while it was suspended is worth nothing. A socket
    /// that still says it is joined is dropped too: iOS can suspend the app with the socket
    /// half-open, and from here that is indistinguishable from a healthy quiet one. One
    /// redial and a sync costs less than sitting on a dead socket until the pong deadline.
    public func reconnect() {
        guard !stopped else { return }
        attempt = 0
        dropAll()
        race()
    }

    /// Back in the foreground with the session up: Local Network access may have been granted meanwhile,
    /// so refused candidates are tried again, and a session on the relay looks for a direct path.
    public func refreshDirect() {
        denied = []
        setReport(localNetworkDenied: false)
        upgrade()
    }

    /// The Settings toggle. On: try the candidates now, which is when iOS asks for Local Network access.
    /// Off: close any direct socket and stay on the relay.
    public func setDirect(_ enabled: Bool) {
        guard enabled != directEnabled else { return }
        directEnabled = enabled
        denied = []
        backoff = [:]
        setReport(localNetworkDenied: false)
        guard !stopped else { return }
        if enabled {
            if current == nil { race() } else { upgrade() }
            return
        }
        upgradeTimer?.cancel()
        for leg in racing where leg.candidate != nil { drop(leg) }
        if let current, current.candidate != nil {
            drop(current)
            sessionEnded()
            race()
        }
    }

    public func close() {
        stopped = true
        if let pushLeg { endPushLeg(pushLeg) }
        dropAll()
        retry?.cancel()
        peerExchange?.cancel()
        updates?.yield(.state(.closed))
        updates?.finish()
        updates = nil
    }

    // MARK: Path

    private func watchNetworkPath() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let lan = path.status == .satisfied && path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
            let vpn = path.status == .satisfied && path.availableInterfaces.contains { $0.type == .other }
            let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",")
            Task { await self?.pathChanged(signature: signature, lan: lan, vpn: vpn) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    /// A real change (another set of interfaces) resets every candidate's backoff and re-races. A direct
    /// session whose kind of network is gone hands over to the relay at once; one whose network is still up
    /// stays, and its heartbeat decides. A relay socket may be left over from the previous network: with
    /// direct candidates to try it is kept while they race, and probed; without, it is redialled.
    private func pathChanged(signature: String, lan: Bool, vpn: Bool) {
        let known = pathSignature != nil
        let changed = known && signature != pathSignature
        pathSignature = signature
        lanUsable = lan
        vpnUsable = vpn
        if changed { backoff = [:] }
        guard !stopped else { return }
        guard known else {
            if current == nil, racing.isEmpty { race() }
            return
        }
        guard changed else { return }
        for leg in racing where leg.candidate.map(usable) == false { drop(leg) }
        guard let current else { return race() }
        if let candidate = current.candidate {
            guard !usable(candidate) else { return }
            drop(current)
            sessionEnded()
            race()
        } else if !eligible().isEmpty {
            upgrade()
            probeSoon()
        } else {
            reconnect()
        }
    }

    private func usable(_ candidate: DirectCandidate) -> Bool {
        candidate.kind == .lan ? lanUsable : vpnUsable
    }

    /// Candidates worth a socket now: the toggle on, a relay-known device with a room to prove, the right
    /// kind of network up, not refused by iOS, not backing off, and not already dialled.
    private func eligible() -> [DirectCandidate] {
        guard directEnabled, paired, pairing.roomId != nil else { return [] }
        let now = ContinuousClock.now
        return candidates.filter { candidate in
            usable(candidate) && !denied.contains(candidate) && (backoff[candidate]?.until ?? now) <= now
                && current?.candidate != candidate && !racing.contains { $0.candidate == candidate }
        }
    }

    // MARK: Race

    /// With no session: direct candidates now, the relay 300 ms later (at once with none). With one on the
    /// relay: an upgrade attempt.
    private func race() {
        guard !stopped else { return }
        retry?.cancel()
        retry = nil
        guard current == nil else { return upgrade() }
        updates?.yield(.state(.connecting))
        let direct = eligible()
        direct.forEach(startDirect)
        guard !racing.contains(where: { $0.route == .relay }), stagger == nil else { return }
        if direct.isEmpty { return startRelay() }
        stagger = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.staggerFired()
        }
    }

    private func staggerFired() {
        stagger = nil
        guard !stopped, current == nil, !racing.contains(where: { $0.route == .relay }) else { return }
        startRelay()
    }

    /// Direct legs beside a relay session; whichever authenticates takes the session over.
    private func upgrade() {
        upgradeTimer?.cancel()
        upgradeTimer = nil
        guard !stopped, let current, current.route == .relay else { return }
        eligible().forEach(startDirect)
        scheduleUpgrade()
    }

    /// While on the relay, the next try comes when the first backed-off candidate is due again.
    private func scheduleUpgrade() {
        guard directEnabled, paired, current?.route == .relay else { return }
        let due = candidates.filter { usable($0) && !denied.contains($0) }.compactMap { backoff[$0]?.until }.min()
        guard let due, due > ContinuousClock.now else { return }
        upgradeTimer?.cancel()
        upgradeTimer = Task {
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            self.upgrade()
        }
    }

    private func scheduleRetry() {
        // Exponential retry with jitter; back to the first interval after a join.
        let delay = min(30, pow(2, Double(attempt))) * Double.random(in: 0.75...1.0)
        attempt += 1
        retry?.cancel()
        retry = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.retry = nil
            self.race()
        }
    }

    private func startRelay() {
        let task = session.webSocketTask(with: dial)
        let leg = Leg(route: .relay, socket: RelaySocket(task))
        racing.append(leg)
        task.resume()
        leg.deadline = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self.fail(leg, String(localized: "relay connection timed out"))
        }
        Task { await self.receiveLoop(leg) }
    }

    private func startDirect(_ candidate: DirectCandidate) {
        let box = WeakLeg()
        let socket = DirectSocket(candidate) { [weak self] denied, reason in
            Task { await self?.directWaiting(box.leg, denied: denied, reason: reason) }
        }
        let leg = Leg(route: .direct(candidate), socket: socket)
        box.leg = leg
        racing.append(leg)
        socket.start()
        // The probe names the room and a nonce, nothing of this phone; NWConnection holds it until the socket is up.
        leg.phoneNonce = DirectProof.newNonce()
        guard let room = pairing.roomId, let probe = try? DirectMessage.probe(room: room, nonce: leg.phoneNonce).text() else { return drop(leg) }
        socket.send(probe) { _ in }
        leg.deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self.fail(leg, String(localized: "direct connection timed out"))
        }
        Task { await self.receiveLoop(leg) }
    }

    /// A waiting direct socket: refused Local Network access is left to wait — iOS may be asking the
    /// user right now — and judged at the deadline; any other reason (refused, unreachable) fails it now.
    private func directWaiting(_ leg: Leg?, denied: Bool, reason: String) {
        guard let leg, tracked(leg) else { return }
        if denied { leg.localNetworkDenied = true } else { fail(leg, reason) }
    }

    private func tracked(_ leg: Leg) -> Bool {
        current === leg || racing.contains { $0 === leg }
    }

    private func receiveLoop(_ leg: Leg) async {
        while tracked(leg) {
            do {
                let text = try await leg.socket.receive()
                guard tracked(leg) else { return }
                if leg.candidate != nil { handleDirect(text, on: leg) } else { handleRelay(text, on: leg) }
            } catch {
                fail(leg, leg.candidate != nil ? leg.socket.closeReason ?? error.localizedDescription : error.localizedDescription)
                return
            }
        }
    }

    /// A leg reached an authenticated `joined`. With no session it takes the session, and a direct winner
    /// cancels the rest (a relay winner leaves direct legs running as upgrade attempts). With the session
    /// on the relay, a direct leg takes it over: `hello` on the direct socket, then the relay closes.
    private func won(_ leg: Leg) {
        racing.removeAll { $0 === leg }
        leg.deadline?.cancel()
        leg.deadline = nil
        if let old = current {
            guard leg.candidate != nil, old.route == .relay else { return drop(leg) }
            current = leg
            begin(on: leg)
            drop(old)
            return
        }
        current = leg
        stagger?.cancel()
        stagger = nil
        retry?.cancel()
        retry = nil
        if leg.candidate != nil { for loser in racing { drop(loser) } }
        begin(on: leg)
    }

    /// Phase 2 on the winner: a new session, whatever came before.
    private func begin(on leg: Leg) {
        resetSession()
        attempt = 0
        upgradeTimer?.cancel()
        upgradeTimer = nil
        if let candidate = leg.candidate {
            if leg.localNetworkDenied || denied.contains(candidate) { setReport(localNetworkDenied: false) }
            updates?.yield(.path(candidate.kind == .lan ? .directLAN(candidate) : .directVPN(candidate)))
            updates?.yield(.state(.joined))
            // The Mac answered on its own socket: it is online by definition.
            updates?.yield(.ownerOnline(true))
            armPhaseDeadline(String(localized: "host handshake timed out"), on: leg)
            startPings(every: .seconds(10))
            Task { await self.sayHello(on: leg) }
            Task { await self.sendPush() }
            return
        }
        if leg.ownerOnline { armPhaseDeadline(String(localized: "host handshake timed out"), on: leg) }
        // The relay remembers this device now, so the one-time token is done with.
        if !paired {
            paired = true
            onPaired?()
        }
        startPings(every: .seconds(30))
        updates?.yield(.path(.relay))
        updates?.yield(.state(.joined))
        updates?.yield(.ownerOnline(leg.ownerOnline))
        // `joined` carried presence as of the instant it was written; ask again so what the
        // UI shows is the relay's live answer rather than anything either end remembered.
        Task { await self.requestOwner(on: leg) }
        Task { await self.sayHello(on: leg) }
        // Where to wake this device, said again: this may be a room that has never heard
        // of us — a redeployed relay, an evicted object — and there is no way to tell.
        Task { await self.sendPush() }
        upgrade()
    }

    private func resetSession() {
        lastFlowAckBytes = 0
        flowFramesSinceAck = 0
        channelFormat = nil
        peerExchange?.cancel()
        peerInfoRequestID = nil
        ready = false
        incompatible = false
        peerInfo = nil
        compatibility = .legacy
        pinger?.cancel()
        pongDeadline?.cancel()
        pongDeadline = nil
        phaseDeadline?.cancel()
        phaseDeadline = nil
    }

    /// The session's leg is gone: its timers go with it.
    private func sessionEnded() {
        pinger?.cancel()
        pongDeadline?.cancel()
        pongDeadline = nil
        phaseDeadline?.cancel()
        phaseDeadline = nil
        peerExchange?.cancel()
        ready = false
    }

    /// Closes a leg on purpose: a loser, a superseded relay, a toggle or path change. No backoff, no error.
    private func drop(_ leg: Leg) {
        racing.removeAll { $0 === leg }
        if current === leg { current = nil }
        leg.deadline?.cancel()
        leg.deadline = nil
        leg.socket.close(code: nil)
    }

    private func dropAll() {
        stagger?.cancel()
        stagger = nil
        retry?.cancel()
        retry = nil
        upgradeTimer?.cancel()
        upgradeTimer = nil
        if let current { drop(current) }
        for leg in racing { drop(leg) }
        sessionEnded()
    }

    /// A leg ended on its own or missed a deadline. A direct candidate backs off (or, refused Local Network
    /// access, is skipped); a relay failure is the user's to see. A lost direct session re-races at once; a
    /// lost relay session, or a race nobody won, waits out the backoff. The Mac's close codes: 4000 (asleep)
    /// backs off every candidate, so the race goes to the relay; 4002 (superseded) backs off none.
    private func fail(_ leg: Leg, _ reason: String) {
        guard tracked(leg) else { return }
        let wasCurrent = current === leg
        if leg.route == .relay, !paired, leg.socket.closeReason == "unknown token" { codeSpent = true }
        drop(leg)
        if wasCurrent {
            sessionEnded()
            if !stopped { updates?.yield(.state(.connecting)) }
        }
        if let candidate = leg.candidate {
            let code = leg.socket.closeCode.flatMap(DirectCloseCode.init(rawValue:))
            if code == .superseded {
                // Not a failure: a newer session of ours took the route, and the next race finds it.
            } else if code == .sleeping {
                for other in candidates { backOff(other) }
                setReport(lastError: "\(candidate.host): \(reason)")
            } else if leg.localNetworkDenied {
                denied.insert(candidate)
                setReport(lastError: String(localized: "Local Network access is off"), localNetworkDenied: true)
            } else {
                backOff(candidate)
                setReport(lastError: "\(candidate.host): \(reason)")
            }
        } else if !stopped {
            updates?.yield(.failed(reason))
        }
        guard !stopped else { return }
        if wasCurrent {
            if leg.candidate != nil { race() } else { scheduleRetry() }
        } else if current == nil, racing.isEmpty {
            if stagger != nil {
                // Every direct candidate failed before the relay's turn: no reason to wait for it.
                stagger?.cancel()
                stagger = nil
                startRelay()
            } else if retry == nil {
                scheduleRetry()
            }
        } else if current?.route == .relay {
            scheduleUpgrade()
        }
    }

    /// 30 s, doubling per failure to 10 minutes.
    private func backOff(_ candidate: DirectCandidate) {
        let failures = (backoff[candidate]?.failures ?? 0) + 1
        let delay = min(600, 30 * pow(2, Double(failures - 1)))
        backoff[candidate] = (failures, ContinuousClock.now + .seconds(delay))
    }

    private func setReport(lastError: String? = nil, localNetworkDenied: Bool? = nil) {
        var next = report
        if let lastError { next.lastError = lastError }
        if let localNetworkDenied { next.localNetworkDenied = localNetworkDenied }
        guard next != report else { return }
        report = next
        updates?.yield(.direct(next))
    }

    // MARK: Heartbeat

    /// The relay drops a socket that says nothing for long enough, and a phone in a quiet chat says nothing
    /// for hours: the relay is pinged every 30 s with a 10 s deadline. The direct path is pinged every 10 s
    /// with a 5 s deadline, which is how a dead LAN leg hands over to the relay in seconds.
    ///
    /// The relay ping is a `{"type":"ping"}` message rather than a websocket ping frame because that is
    /// what the relay answers at its edge, leaving the room itself hibernated.
    private func startPings(every interval: Duration) {
        pinger?.cancel()
        pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self.probe()
            }
        }
    }

    /// One ping on the session's socket, and a deadline its pong disarms. A missed one fails the leg — the
    /// only way a phone can tell a half-open socket from an idle one.
    private func probe() async {
        guard pongDeadline == nil, let leg = current else { return }
        let direct = leg.candidate != nil
        pongDeadline = Task {
            try? await Task.sleep(for: .seconds(direct ? 5 : 10))
            guard !Task.isCancelled else { return }
            self.pongDeadline = nil
            self.fail(leg, direct ? String(localized: "Mac stopped answering") : String(localized: "Relay stopped answering"))
        }
        // A send that throws means the socket is already gone, and the receive loop reports that.
        if direct {
            try? await transmit(DirectMessage.ping(t: Self.now).text(), on: leg)
        } else {
            try? await send(["type": "ping"], on: leg)
        }
    }

    private func probeSoon() {
        Task { await self.probe() }
    }

    private func armPhaseDeadline(_ reason: String, on leg: Leg) {
        phaseDeadline?.cancel()
        phaseDeadline = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, self.current === leg, !self.ready else { return }
            self.phaseDeadline = nil
            self.fail(leg, reason)
        }
    }

    // MARK: Sending

    /// Seals `event` under the device->mac key, numbered, and sends it as one signed frame on the session's
    /// socket. The counter is persisted before the frame leaves: a `seq` that went out and was then
    /// forgotten would be reused after a relaunch, and the Mac would drop the reuse as a replay.
    ///
    /// Allowed before the handshake once joined on a replay-protected channel: the channel keys
    /// are fixed by the pairing, so a box sealed while the Mac is away is one the relay buffers
    /// and the Mac opens when it comes back. A legacy or not-yet-known channel still waits.
    public func send(_ event: YorozuEvent) async throws {
        guard !incompatible, ready || (current != nil && sealFormat == .current) else {
            throw YorozuCrypto.CryptoError.malformed(String(localized: "Host compatibility has not been established"))
        }
        try await sendEncrypted(event, track: true)
        // A send is when a silently dead socket costs the user something, so it probes now
        // rather than waiting out the idle ping. One probe covers a burst of sends.
        if pongDeadline == nil { await probe() }
    }

    /// The format this session seals in: the one the Mac answered in, or, while it has not answered
    /// on this session, the current one if this pairing ever completed the 0.7 peer exchange.
    private var sealFormat: ChannelFormat? {
        channelFormat ?? (counter.peerInfoRequired == true ? .current : nil)
    }

    /// `track` maps the frame's signature to `event.id` for the relay's `accepted` reply.
    private func sendEncrypted(_ event: YorozuEvent, track: Bool = false) async throws {
        try Task.checkCancellation()
        guard !stopped, !incompatible else { throw YorozuCrypto.CryptoError.malformed(String(localized: "Host connection is closed")) }
        guard let format = sealFormat else {
            throw YorozuCrypto.CryptoError.malformed(String(localized: "Mac has not answered pairing"))
        }
        let eventId = track ? event.id : nil
        if format == .legacy {
            let box = try YorozuCrypto.seal(key: legacyKey, plaintext: JSONEncoder().encode(event))
            try await sendFrame(FrameBody(t: "box", n: box.nonce.base64URLEncodedString(),
                c: box.ciphertext.base64URLEncodedString()), eventId: eventId)
            return
        }
        let envelope = ChannelEnvelope(seq: counter.next(), event: event)
        // Recorded before it is sealed, and not sent at all if it cannot be: the counter in
        // memory has moved on either way, so a retry takes the next `seq`, never this one.
        try counterStore.save(counter)
        let box = try YorozuCrypto.seal(key: channelKeys.send, plaintext: try envelope.encoded())
        try await sendFrame(
            FrameBody(
                t: "box",
                n: box.nonce.base64URLEncodedString(),
                c: box.ciphertext.base64URLEncodedString()
            ),
            eventId: eventId
        )
    }

    /// The signed frame, on the session's socket: the relay's `{type:"frame",payload,sig}` or the direct
    /// path's `{type:"frame",frame:{payload,sig}}`. Both sign the base64url `payload` string itself.
    /// With `eventId` on the relay, the signature is mapped to it before the frame leaves, so an `accepted`
    /// that arrives before the send completes still finds it. The direct path has no `accepted`.
    private func sendFrame(_ body: FrameBody, eventId: String? = nil, on target: Leg? = nil) async throws {
        guard let leg = target ?? current else { throw YorozuCrypto.CryptoError.malformed(String(localized: "not connected")) }
        let payload = try JSONEncoder().encode(body).base64URLEncodedString()
        let sig = try YorozuCrypto.signFrame(
            priv: identity.signingPrivateKey,
            data: Data(payload.utf8)
        ).base64URLEncodedString()
        if leg.candidate != nil {
            try await transmit(DirectMessage.frame(payload: payload, sig: sig).text(), on: leg)
            return
        }
        if let eventId { leg.sentSigs[sig] = eventId }
        do {
            try await send(["type": "frame", "payload": payload, "sig": sig], on: leg)
        } catch {
            if eventId != nil { leg.sentSigs[sig] = nil }
            throw error
        }
    }

    private func send(_ message: [String: String], on leg: Leg) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await transmit(String(decoding: data, as: UTF8.self), on: leg)
    }

    private func transmit(_ text: String, on leg: Leg) async throws {
        let socket = leg.socket
        // Enqueue on the socket before actor reentrancy: channel seq assignment and frame
        // emission must stay ordered even when an earlier send completion stalls.
        let (result, continuation) = AsyncStream<Result<Void, any Error>>.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        socket.send(text) { error in
            continuation.yield(error.map { .failure($0) } ?? .success(()))
            continuation.finish()
        }
        try await sendWithDeadline(onTimeout: { socket.close(code: nil) }) {
            guard let outcome = await result.first(where: { _ in true }) else { throw CancellationError() }
            try outcome.get()
        }
    }

    // MARK: Relay

    /// Everything here is attacker-controlled; a malformed frame must not tear the client down,
    /// so per-frame decode failures are skipped rather than thrown.
    private func handleRelay(_ text: String, on leg: Leg) {
        guard let message = try? JSONDecoder().decode(Inbound.self, from: Data(text.utf8)) else { return }
        let live = current === leg
        switch message.type {
        case "nonce":
            // The relay challenges every socket; only the Mac registers. We join.
            guard !leg.joined else { return }
            leg.nonce = message.nonce ?? ""
            Task { await self.join(leg) }
        case "joined":
            guard !leg.joined else { return }
            leg.joined = true
            leg.flowControl = message.flowControl == true
            leg.ownerOnline = message.ownerOnline == true
            won(leg)
        case "pong":
            guard live else { return }
            pongDeadline?.cancel()
            pongDeadline = nil
        case "accepted":
            // Only frames this socket sent carry a known signature; anything else is ignored.
            if let sig = message.sig, let eventId = leg.sentSigs.removeValue(forKey: sig) {
                updates?.yield(.accepted(eventId: eventId, buffered: message.buffered == true))
            }
        case "owner":
            guard live else { return }
            if message.online == true {
                updates?.yield(.ownerOnline(true))
                if !ready, phaseDeadline == nil {
                    armPhaseDeadline(String(localized: "host handshake timed out"), on: leg)
                    Task { await self.sayHello(on: leg) }
                }
            } else {
                ready = false
                channelFormat = nil
                peerInfoRequestID = nil
                peerExchange?.cancel()
                updates?.yield(.state(.joined))
                updates?.yield(.ownerOnline(false))
                phaseDeadline?.cancel()
                phaseDeadline = nil
            }
        case "frame":
            guard live else { return }
            acceptFrame(message.payload)
            if leg.flowControl, let bytes = message.flowBytes, bytes > lastFlowAckBytes {
                flowFramesSinceAck += 1
                if bytes - lastFlowAckBytes >= 1_048_576 || flowFramesSinceAck >= 16 {
                    lastFlowAckBytes = bytes
                    flowFramesSinceAck = 0
                    Task { try? await self.send(["type": "flowAck", "bytes": String(bytes)], on: leg) }
                }
            }
        default:
            break
        }
    }

    /// The first join spends the one-time token from the pairing code. Every later one signs the
    /// connect nonce instead — the same challenge the Mac answers — which is what lets the phone
    /// come back after a background, a network change or a relaunch without pairing again.
    private func join(_ leg: Leg) async {
        guard tracked(leg) || leg === pushLeg else { return }
        do {
            let rejoin = paired || codeSpent
            let challenge = rejoin ? leg.nonce : pairing.token
            let signature = try YorozuCrypto.signFrame(
                priv: identity.signingPrivateKey,
                data: Data(challenge.utf8)
            )
            var message = [
                "type": "join",
                "roomId": pairing.roomId ?? "",
                "phonePubkey": identity.signingPublicKey.base64URLEncodedString(),
                "sig": signature.base64URLEncodedString(),
            ]
            if !rejoin { message["token"] = pairing.token }
            try await send(message, on: leg)
        } catch {
            updates?.yield(.failed(error.localizedDescription))
        }
    }

    /// The app's own APNs device token, which alerts are addressed to. `relayKnows`: `onPushSent` reported
    /// this token before, so a direct session need not join the relay to say it.
    public func registerPush(deviceToken: String, relayKnows: Bool = false) async {
        self.deviceToken = deviceToken
        pushOwed = !relayKnows
        await sendPush()
    }

    /// Where this device can be woken, said again. Nothing to say until APNs has answered with
    /// a token, and nothing to say it on until a session is up: a relay one carries it, a direct
    /// one joins the relay once if the relay has not heard this token.
    private func sendPush() async {
        guard let leg = current, let deviceToken else { return }
        guard leg.route == .relay else { return pushOwed ? startPushLeg() : () }
        if (try? await send(["type": "push", "deviceToken": deviceToken], on: leg)) != nil { pushSent(deviceToken) }
    }

    private func pushSent(_ token: String) {
        guard token == deviceToken else { return }
        pushOwed = false
        onPushSent?(token)
    }

    /// A relay socket beside a direct session: join (as a known device), say `push`, hang up.
    private func startPushLeg() {
        guard pushLeg == nil, paired, !stopped else { return }
        let task = session.webSocketTask(with: dial)
        let leg = Leg(route: .relay, socket: RelaySocket(task))
        pushLeg = leg
        task.resume()
        leg.deadline = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self.endPushLeg(leg)
        }
        Task {
            defer { self.endPushLeg(leg) }
            while self.pushLeg === leg, let text = try? await leg.socket.receive() {
                guard let message = try? JSONDecoder().decode(Inbound.self, from: Data(text.utf8)) else { continue }
                if message.type == "nonce", !leg.joined {
                    leg.nonce = message.nonce ?? ""
                    await self.join(leg)
                } else if message.type == "joined", let token = self.deviceToken {
                    leg.joined = true
                    if (try? await self.send(["type": "push", "deviceToken": token], on: leg)) != nil { self.pushSent(token) }
                    return
                }
            }
        }
    }

    private func endPushLeg(_ leg: Leg) {
        guard pushLeg === leg else { return }
        pushLeg = nil
        leg.deadline?.cancel()
        leg.socket.close(code: URLSessionWebSocketTask.CloseCode.normalClosure.rawValue)
    }

    /// Asks the relay whether the room's Mac holds a socket right now. The reply is an ordinary
    /// `owner` message, so it lands in the same place the relay's unprompted ones do.
    private func requestOwner(on leg: Leg) async {
        guard current === leg else { return }
        try? await send(["type": "owner"], on: leg)
    }

    // MARK: Direct

    /// The direct handshake (docs/ios-relay-contract.md, "Direct path"): `probe` went out on connect; accept
    /// `joined` only from the key the QR's room is the hash of, signed over the probe's nonce, and only then
    /// name this phone in a signed `join` over the Mac's nonce. After that, frames signed by that key.
    private func handleDirect(_ text: String, on leg: Leg) {
        guard let message = DirectMessage.decode(text), let room = pairing.roomId else { return }
        switch message {
        case .joined(let pub, let sig, let nonce):
            guard !leg.joined, !leg.phoneNonce.isEmpty else { return }
            guard let key = Data(base64URLEncoded: pub), let signature = Data(base64URLEncoded: sig),
                  DirectProof.verifyJoined(pub: key, room: room, phoneNonce: leg.phoneNonce, signature: signature) else {
                return fail(leg, String(localized: "The direct listener is not this Mac"))
            }
            guard Data(base64URLEncoded: nonce)?.count == 32,
                  let proof = try? DirectProof.signJoin(priv: identity.signingPrivateKey, room: room, macNonce: nonce),
                  let join = try? DirectMessage.join(room: room, pub: identity.signingPublicKey.base64URLEncodedString(),
                                                     sig: proof.base64URLEncodedString()).text() else {
                return fail(leg, String(localized: "The direct listener is not this Mac"))
            }
            leg.nonce = nonce
            leg.joined = true
            leg.macKey = key
            // Enqueued before `won` sends `hello`, so the Mac sees the join first; a join it refuses closes with 4001.
            leg.socket.send(join) { _ in }
            won(leg)
        case .frame(let payload, let sig):
            guard current === leg, let key = leg.macKey, let signature = Data(base64URLEncoded: sig),
                  YorozuCrypto.verifyFrame(pub: key, data: Data(payload.utf8), signature: signature) else { return }
            acceptFrame(payload)
        case .pong:
            guard current === leg else { return }
            pongDeadline?.cancel()
            pongDeadline = nil
        case .probe, .join, .ping:
            break
        }
    }

    // MARK: Session

    private func sayHello(on leg: Leg) async {
        guard current === leg else { return }
        do {
            let pub = identity.sessionPublicKey.base64URLEncodedString()
            let spub = identity.signingPublicKey.base64URLEncodedString()
            // Sent every time rather than only first: the Mac may have lost `devices.json`, and
            // a `hello` it cannot verify is a phone it will not seal for. The relay saw the
            // secret's hash and nothing else, and the hash is bound to these two keys alone.
            let proof = pairing.secret.map { YorozuCrypto.helloProof(secret: $0, pub: pub, spub: spub) }
            try await sendFrame(FrameBody(t: "hello", pub: pub, spub: spub, proof: proof), on: leg)
        } catch {
            if leg.route == .relay { updates?.yield(.failed(error.localizedDescription)) }
        }
    }

    func acceptFrame(_ payload: String?) {
        guard !incompatible else { return }
        guard let payload, let raw = Data(base64URLEncoded: payload),
            let body = try? JSONDecoder().decode(FrameBody.self, from: raw),
            body.t == "box",
            let nonce = body.n.flatMap({ Data(base64URLEncoded: $0) }),
            let ciphertext = body.c.flatMap({ Data(base64URLEncoded: $0) })
        else { return }
        // Several phones can be paired at once: the Mac seals a copy per device and the relay
        // broadcasts all of them, so a frame we cannot open is simply another device's and is
        // dropped without a word. Our own boxes, reflected, fail the same way: they were
        // sealed under the other direction's key.
        let current = try? YorozuCrypto.open(key: channelKeys.recv, nonce: nonce, ciphertext: ciphertext)
        if current == nil {
            // The first old-format box must be the Mac's greeting. Once a modern box has
            // arrived, old captured boxes cannot switch this connection back.
            if channelFormat == .current || counter.peerInfoRequired == true { return }
            guard let plain = try? YorozuCrypto.open(key: legacyKey, nonce: nonce, ciphertext: ciphertext) else { return }
            guard let event = try? JSONDecoder().decode(YorozuEvent.self, from: plain) else {
                rejectMalformedPeerClaim(plain, numbered: false)
                return
            }
            if case .unknown(let kind, _) = event.payload, kind == "thread_list" {
                rejectMalformedPeerClaim(plain, numbered: false)
                if incompatible { return }
            }
            if channelFormat == nil {
                guard case .threadList = event.payload else { return }
                channelFormat = .legacy
            }
            receiveAuthenticated(event)
            return
        }
        guard let plain = current else { return }
        // A replay or a malformed envelope is logged, not surfaced: `.failed` would put an error
        // banner in front of the user for something the relay, not the Mac, did.
        guard let envelope = try? ChannelEnvelope.decode(plain) else {
            rejectMalformedPeerClaim(plain, numbered: true)
            logger.notice("dropped box with a malformed envelope")
            return
        }
        if case .unknown(let kind, _) = envelope.event.payload, kind == "thread_list" {
            rejectMalformedPeerClaim(plain, numbered: true)
            if incompatible { return }
        }
        guard counter.accept(envelope.seq) else {
            logger.notice("dropped box with seq \(envelope.seq) at or below \(self.counter.recv)")
            return
        }
        // Written before the event is handed on, so a relaunch between the two cannot be made
        // to take the same box again; a box whose acceptance cannot be recorded is not handed
        // on at all. Only the numbers are logged, never what the box carried.
        do {
            try counterStore.save(counter)
        } catch {
            logger.error("dropped box with seq \(envelope.seq): counter could not be saved")
            return
        }
        channelFormat = .current
        receiveAuthenticated(envelope.event)
    }

    private func receiveAuthenticated(_ event: YorozuEvent) {
        if case .threadList(let list) = event.payload {
            if peerInfoRequestID == nil && (list.peerInfoSupported == true || list.peerInfo != nil || list.peerInfoError != nil) {
                requestPeerInfo()
                return
            }
            if !ready, (list.peerInfo != nil || list.peerInfoError != nil), list.peerInfoReplyTo != peerInfoRequestID {
                return
            }
            if let reason = list.peerInfoError {
                failCompatibility(reason)
                return
            }
            if let peer = list.peerInfo {
                let result = localPeer.compatibility(with: peer)
                if case .updateRequired(let reason) = result { failCompatibility(reason); return }
                guard channelFormat == .current else {
                    failCompatibility(String(localized: "A replay-protected channel is required. Update Yorozu on the host Mac."))
                    return
                }
                compatibility = result
                var accepted = peer
                if case .compatible(_, let capabilities) = result, !capabilities.contains("host-name") {
                    accepted.computerName = nil
                }
                learnCandidates(accepted, result)
                accepted.directCandidates = candidates
                peerInfo = accepted
                updates?.yield(.compatibility(result))
                updates?.yield(.peerInfo(accepted))
            } else if list.peerInfoSupported == true {
                if ready { requestPeerInfo() }
                return
            } else if peerInfoRequestID != nil || counter.peerInfoRequired == true ||
                        localPeer.requiredCapabilities.contains("admission-expiry-v1") {
                failCompatibility(String(localized: "This host no longer advertises required protocol support. Update Yorozu on the host Mac."))
                return
            }
            if !ready {
                ready = true
                phaseDeadline?.cancel()
                phaseDeadline = nil
                // A direct session that got this far is healthy: its candidate starts its backoff afresh.
                if let candidate = current?.candidate { backoff[candidate] = nil }
                updates?.yield(.compatibility(compatibility))
                updates?.yield(.state(.paired))
            }
        }
        guard ready else { return }
        updates?.yield(.event(event))
    }

    /// The host's direct addresses, from a replay-protected peer exchange that negotiated `direct-v1`;
    /// none otherwise. New ones are tried at once when the session is on the relay.
    private func learnCandidates(_ peer: PeerInfoData, _ result: PeerCompatibility) {
        var next: [DirectCandidate] = []
        if case .compatible(_, let capabilities) = result, capabilities.contains(DirectCandidate.capability) {
            next = peer.directCandidates ?? []
        }
        guard next != candidates else { return }
        candidates = next
        backoff = backoff.filter { next.contains($0.key) }
        denied = denied.filter { next.contains($0) }
        for leg in racing where leg.candidate.map({ !next.contains($0) }) == true { drop(leg) }
        if current?.route == .relay { upgrade() }
    }

    private func requestPeerInfo() {
        guard channelFormat == .current else {
            failCompatibility(String(localized: "A replay-protected channel is required. Update Yorozu on the host Mac."))
            return
        }
        ready = false
        counter.peerInfoRequired = true
        guard (try? counterStore.save(counter)) != nil else { return }
        let requestID = UUID().uuidString
        peerInfoRequestID = requestID
        let request = YorozuEvent(id: requestID, threadId: "", ts: Self.now,
            agentId: "device", payload: .threadList(ThreadListData(threads: [], peerInfo: localPeer)))
        peerExchange = Task {
            do { try await self.sendEncrypted(request) }
            catch { self.updates?.yield(.failed(error.localizedDescription)) }
        }
    }

    private func failCompatibility(_ reason: String) {
        incompatible = true
        ready = false
        compatibility = .updateRequired(reason)
        updates?.yield(.compatibility(compatibility))
        updates?.yield(.state(.closed))
        updates?.yield(.failed(String(localized: "Update required: \(reason)")))
        let leg = current
        current = nil
        stopped = true
        dropAll()
        leg?.socket.close(code: URLSessionWebSocketTask.CloseCode.policyViolation.rawValue)
    }

    /// Strict typed decoding rejects bad claims. Identify that failure only after authentication
    /// and freshness checking, so a replay cannot force a healthy host into Update required.
    private func rejectMalformedPeerClaim(_ plain: Data, numbered: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
            let event = numbered ? object["event"] as? [String: Any] : object,
            event["kind"] as? String == "thread_list",
            let data = event["data"] as? [String: Any],
            data.keys.contains("peerInfo") || data.keys.contains("peerInfoSupported") || data.keys.contains("peerInfoError") || data.keys.contains("peerInfoReplyTo") else { return }
        if numbered {
            struct Sequence: Decodable { var seq: Int }
            guard let seq = try? JSONDecoder().decode(Sequence.self, from: plain).seq,
                (1...ChannelEnvelope.maxSeq).contains(seq), counter.accept(seq) else { return }
            counter.peerInfoRequired = true
            guard (try? counterStore.save(counter)) != nil else { return }
        }
        failCompatibility(String(localized: "Invalid peer information. Update Yorozu on this device and its host Mac."))
    }

    private static var now: Int { Int(Date().timeIntervalSince1970 * 1_000) }
}

/// Lets a socket callback created before its leg find it later.
private final class WeakLeg: @unchecked Sendable {
    weak var leg: Leg?
}
