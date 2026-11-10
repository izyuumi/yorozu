import Foundation
import Network
import Testing
@testable import YorozuWire

struct RelayLegTests {
    // Preventive coverage: no failing pairing-standing baseline. Expectations preserve the existing wire policy.
    @Test func closeDecisionMatchesTheWirePolicy() {
        let standings: [RelayConnection.Standing] = [.knownToRelay,
            .codeOnly(retriedAsKnown: false), .codeOnly(retriedAsKnown: true),
            .pairedDirect(retriedAsKnown: false), .pairedDirect(retriedAsKnown: true)]
        let rows: [(String, [RelayConnection.CloseOutcome])] = [
            ("revoked", Array(repeating: .terminal(.unpaired), count: 5)),
            ("unknown device", [.terminal(.unpaired), .terminal(.pairingFailed("unknown device")),
                .terminal(.pairingFailed("unknown device")), .retry, .retry]),
            ("unknown token", [.terminal(.pairingFailed("unknown token")), .retryAsKnown,
                .terminal(.pairingFailed("unknown token")), .retryAsKnown, .retry]),
            ("expired token", [.terminal(.pairingFailed("expired token")), .terminal(.pairingFailed("expired token")),
                .terminal(.pairingFailed("expired token")), .retryAsKnown, .retry]),
            ("host offline", Array(repeating: .retry, count: 5)),
            ("pairing expired", Array(repeating: .retry, count: 5)),
            ("", Array(repeating: .retry, count: 5)),
            // A reason this client does not recognize never ends the pairing: it retries.
            ("unauthorized", Array(repeating: .retry, count: 5)),
            ("internal error", Array(repeating: .retry, count: 5)),
            ("some future reason", Array(repeating: .retry, count: 5)),
        ]
        for (reason, outcomes) in rows {
            for (standing, expected) in zip(standings, outcomes) {
                let actual = RelayConnection.afterClose(reason: reason, standing: standing)
                #expect(actual == expected, "reason: \(reason), standing: \(standing)")
            }
        }
    }

    // Preventive: no failing baseline. Only `revoked`, and `unknown device` once the relay knew this device, unpair.
    @Test func onlyRevocationUnpairsAKnownDevice() {
        let reasons = ["revoked", "unknown device", "unknown token", "expired token", "host offline",
            "pairing expired", "", "unauthorized", "internal error", "some future reason"]
        let unpairing = reasons.filter {
            RelayConnection.afterClose(reason: $0, standing: .knownToRelay) == .terminal(.unpaired)
        }
        #expect(unpairing == ["revoked", "unknown device"])
        for standing: RelayConnection.Standing in [.codeOnly(retriedAsKnown: false), .codeOnly(retriedAsKnown: true),
            .pairedDirect(retriedAsKnown: false), .pairedDirect(retriedAsKnown: true)] {
            let unpairing = reasons.filter {
                RelayConnection.afterClose(reason: $0, standing: standing) == .terminal(.unpaired)
            }
            #expect(unpairing == ["revoked"], "standing: \(standing)")
        }
    }

    // Preventive: no failing baseline; pins the allowed transitions.
    @Test func standingTransitionsMatchTheAllowedPolicy() {
        let rows: [(standing: RelayConnection.Standing, joined: RelayConnection.Standing,
            retried: RelayConnection.Standing, opened: RelayConnection.Standing)] = [
            (.knownToRelay, .knownToRelay, .knownToRelay, .knownToRelay),
            (.codeOnly(retriedAsKnown: false), .knownToRelay,
                .codeOnly(retriedAsKnown: true), .pairedDirect(retriedAsKnown: false)),
            (.codeOnly(retriedAsKnown: true), .knownToRelay,
                .codeOnly(retriedAsKnown: true), .pairedDirect(retriedAsKnown: true)),
            (.pairedDirect(retriedAsKnown: false), .knownToRelay,
                .pairedDirect(retriedAsKnown: true), .pairedDirect(retriedAsKnown: false)),
            (.pairedDirect(retriedAsKnown: true), .knownToRelay,
                .pairedDirect(retriedAsKnown: true), .pairedDirect(retriedAsKnown: true)),
        ]
        for row in rows {
            #expect(row.standing.afterJoined() == row.joined, "standing: \(row.standing)")
            #expect(row.standing.afterRetryAsKnown() == row.retried, "standing: \(row.standing)")
            #expect(row.standing.afterSessionOpened() == row.opened, "standing: \(row.standing)")
        }
    }

    // Preventive: no failing baseline; pins the allowed transitions.
    @Test func knownToRelayIsAbsorbing() {
        let standing = RelayConnection.Standing.knownToRelay
        #expect(standing.afterJoined() == .knownToRelay)
        #expect(standing.afterRetryAsKnown() == .knownToRelay)
        #expect(standing.afterSessionOpened() == .knownToRelay)
    }

    // Preventive: no failing baseline; pins the allowed transitions.
    @Test func retryAsKnownIsIdempotent() {
        let standings: [RelayConnection.Standing] = [.knownToRelay,
            .codeOnly(retriedAsKnown: false), .codeOnly(retriedAsKnown: true),
            .pairedDirect(retriedAsKnown: false), .pairedDirect(retriedAsKnown: true)]
        for standing in standings {
            let once = standing.afterRetryAsKnown()
            #expect(once.afterRetryAsKnown() == once, "standing: \(standing)")
        }
    }

    // Preventive: no failing baseline; pins the allowed transitions.
    @Test func closeNeverRetriesAsKnownTwice() {
        let standings: [RelayConnection.Standing] = [
            .codeOnly(retriedAsKnown: true), .pairedDirect(retriedAsKnown: true)]
        let reasons = ["revoked", "unknown device", "unknown token", "expired token",
            "host offline", "pairing expired", ""]
        for standing in standings {
            for reason in reasons {
                #expect(RelayConnection.afterClose(reason: reason, standing: standing) != .retryAsKnown,
                    "reason: \(reason), standing: \(standing)")
            }
        }
    }

    @Test func aRelayLegAsksTheRaceAgainAfterTheHostReturns() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        let relay = try LoopbackRelay()
        defer { relay.stop() }
        try await relay.wait(until: deadline, "loopback listener ready") { $0.port != nil }
        let port = try #require(relay.snapshot.port)
        let host = YorozuCrypto.generateKeypair()
        let room = UUID().uuidString
        let pairing = QrPayload(v: 3, relayUrl: "ws://127.0.0.1:\(port)",
            macPubkey: host.publicKey.base64URLEncodedString(), token: UUID().uuidString, roomId: room)
        let dial = try #require(URL(string: "ws://127.0.0.1:\(port)/?room=\(room)"))
        let urlSession = URLSession(configuration: .ephemeral)
        defer { urlSession.invalidateAndCancel() }
        let leg = RelayConnection(path: .relay, dial: dial, pairing: pairing, identity: .generate(),
            relayKnows: true, local: PeerInfo(app: "relay-leg-test"), urlSession: urlSession)
        await leg.gate { relay.ready() }
        let updates = await leg.updates()
        let observer = Task {
            for await update in updates {
                if case .state(.hostOffline) = update { relay.hostOffline() }
            }
        }
        defer { observer.cancel() }
        do {
            await leg.start()
            try await relay.wait(until: deadline, "first ready gate") { $0.readyCount == 1 }
            #expect(relay.snapshot.initCount == 0)
            try #require(await leg.grant())
            try await relay.wait(until: deadline, "first Noise init") { $0.initCount == 1 }

            relay.owner(online: false)
            try await relay.wait(until: deadline, "hostOffline update") { $0.hostOffline }
            relay.owner(online: true)
            // Leave the new grant withheld, as when a direct leg holds the race.
            try await Task.sleep(for: .milliseconds(500))
            let returned = relay.snapshot
            #expect(returned.readyCount == 2, "host return must ask the race again")
            #expect(returned.initCount == 1, "no second init before a second grant")
            try #require(await leg.grant(), "host return must await a fresh grant")
            try await relay.wait(until: deadline, "second Noise init after grant") { $0.initCount == 2 }
            #expect(relay.snapshot.connections == 1, "host return must use the same relay socket")
            await leg.stop()
        } catch {
            await leg.stop()
            throw error
        }
    }
}

/// Real WebSocket relay; never answers Noise, so every frame must be an init.
private final class LoopbackRelay: @unchecked Sendable {
    struct Snapshot {
        var port: UInt16?
        var readyCount = 0
        var initCount = 0
        var connections = 0
        var hostOffline = false
        var failure: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "yorozu.tests.loopback-relay")
    private let lock = NSLock()
    private var recorded = Snapshot()
    // Connections and all WebSocket operations belong to queue; recorded belongs to lock.
    private var connections: [NWConnection] = []

    var snapshot: Snapshot { lock.withLock { recorded } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.lock.withLock { self.recorded.port = self.listener.port?.rawValue }
            case .failed(let error): self.fail("listener: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            self.lock.withLock { self.recorded.connections += 1 }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(["type": "nonce", "nonce": "n1"], on: connection)
                    self.receive(on: connection)
                case .failed(let error): self.fail("connection: \(error)")
                default: break
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    func ready() { lock.withLock { recorded.readyCount += 1 } }
    func hostOffline() { lock.withLock { recorded.hostOffline = true } }
    private func fail(_ message: String) { lock.withLock { recorded.failure = message } }

    func owner(online: Bool) {
        queue.async {
            guard let connection = self.connections.first else { return self.fail("no relay socket") }
            self.send(["type": "owner", "online": online], on: connection)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    func wait(until deadline: ContinuousClock.Instant, _ what: String,
        _ check: (Snapshot) -> Bool) async throws {
        while ContinuousClock.now < deadline {
            let state = snapshot
            if let failure = state.failure { throw ProbeFailure(message: failure) }
            if check(state) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProbeFailure(message: "timed out: \(what)")
    }

    private func send(_ message: [String: Any], on connection: NWConnection) {
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "relay", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    if let error { self?.fail("send: \(error)") }
                })
        } catch { fail("encode: \(error)") }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error { self.fail("receive: \(error)"); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { return }
            if let data, metadata?.opcode == .text {
                do {
                    let message = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    switch message["type"] as? String {
                    case "join":
                        let room = try #require(message["roomId"] as? String)
                        self.send(["type": "joined", "roomId": room, "ownerOnline": true,
                            "flowControl": false], on: connection)
                    case "frame":
                        let payload = try #require(message["payload"] as? String)
                        guard case .handshakeInit = try Frame(payload: payload) else {
                            self.fail("unexpected non-init frame before session opens")
                            return
                        }
                        self.lock.withLock { self.recorded.initCount += 1 }
                    default: break
                    }
                } catch { self.fail("client message: \(error)") }
            }
            self.receive(on: connection)
        }
    }

    private struct ProbeFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
