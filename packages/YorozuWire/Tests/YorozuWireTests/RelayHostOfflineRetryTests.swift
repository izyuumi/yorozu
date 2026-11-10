import CryptoKit
import Foundation
import Network
import Testing
@testable import YorozuWire

struct RelayHostOfflineRetryTests {
    @Test func freshPairingRetriesHostOfflineWithRetainedToken() async throws {
        try await assertHostOfflineRetry(relayKnows: false)
    }

    @Test func knownDeviceRetriesHostOfflineWithNonce() async throws {
        try await assertHostOfflineRetry(relayKnows: true)
    }

    private func assertHostOfflineRetry(relayKnows: Bool) async throws {
        try await withRelay(relayKnows: relayKnows) { server, updates, identity, pairing in
            // `.hostOffline` arrives only with the third, accepted join: two refusals, so two backoffs
            // (1 s + 2 s), around three dial/join/close cycles. A fixed 6 s wait was too close to that
            // and timed out in CI at 6.092 s, so the wait is the schedule plus slack for each cycle.
            let backoffs = (1...2).map(retryBackoff)
            let cycleSlack = Duration.seconds(5)
            try await eventually(within: backoffs.reduce(.zero, +) + cycleSlack * (backoffs.count + 1)) {
                await updates.entries.last?.state == .hostOffline
            }
            let snapshot = await server.snapshot()
            #expect(snapshot.errors.isEmpty, "Server errors: \(snapshot.errors)")
            #expect(snapshot.dials.count == 3)
            #expect(snapshot.joins.count == 3)
            #expect(snapshot.joins.map(\.accepted) == [false, false, true])
            guard snapshot.dials.count == 3, snapshot.joins.count == 3 else { return }
            // 100 ms under each backoff: the server stamps a dial slightly after the client starts it.
            #expect(snapshot.dials[1] - snapshot.dials[0] >= backoffs[0] - .milliseconds(100))
            #expect(snapshot.dials[2] - snapshot.dials[1] >= backoffs[1] - .milliseconds(100))
            #expect(Set(snapshot.joins.map(\.nonce)).count == 3)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.signingPublicKey)
            for join in snapshot.joins {
                #expect(join.message["phonePubkey"] == identity.signingPublicKey.base64URLEncodedString())
                #expect(join.message["roomId"] == pairing.roomId)
                #expect(join.message["token"] == (relayKnows ? nil : pairing.token))
                let signature = try #require(join.message["sig"].flatMap { Data(base64URLEncoded: $0) })
                let challenge = relayKnows ? join.nonce : pairing.token
                #expect(publicKey.isValidSignature(signature, for: Data(challenge.utf8)))
            }
            let entries = await updates.entries
            #expect(!entries.contains { $0.isPairingTerminal })
            let joined = entries.filter { if case .relayJoined = $0.update { true } else { false } }
            #expect(joined.count == (relayKnows ? 0 : 1))
            if let event = joined.first {
                #expect(event.at >= snapshot.joins[2].at)
            }
            #expect(entries.last?.state == .hostOffline)
        }
    }

    @Test func revokedIsTerminalWithoutRedial() async throws {
        try await withRelay(relayKnows: false, refusals: .max, reason: "revoked") { server, updates, _, _ in
            try await eventually { await updates.entries.last?.state == .unpaired }
            try await Task.sleep(for: .milliseconds(2_500))
            let snapshot = await server.snapshot()
            #expect(snapshot.errors.isEmpty, "Server errors: \(snapshot.errors)")
            #expect(snapshot.dials.count == 1)
            #expect(snapshot.joins.count == 1)
            #expect(snapshot.joins.first?.accepted == false)
            let entries = await updates.entries
            #expect(entries.last?.state == .unpaired)
            #expect(!entries.contains { if case .relayJoined = $0.update { true } else { false } })
        }
    }
}

/// The wait before retry `attempt` (from 1), as `RelayConnection.scheduleRetry` computes it:
/// `min(30, 1 << min(attempt - 1, 5))` seconds. The dial-gap expectations fail if production waits less.
private func retryBackoff(attempt: Int) -> Duration {
    .seconds(min(30, 1 << min(attempt - 1, 5)))
}

/// The default covers a wait with nothing scheduled in front of it (the listener's port, a first close).
private func eventually(within limit: Duration = .seconds(6), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw RetryHarnessError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum RetryHarnessError: Error {
    case timedOut
    case listener(String)
}

private actor RetryUpdates {
    struct Entry: Sendable {
        let update: RelayConnection.Update
        let at: ContinuousClock.Instant

        var state: RelayConnection.State? {
            if case .state(let state) = update { state } else { nil }
        }

        var isPairingTerminal: Bool {
            switch state {
            case .some(.pairingFailed(_)), .some(.unpaired): true
            default: false
            }
        }
    }

    private(set) var entries: [Entry] = []

    func record(_ update: RelayConnection.Update) {
        entries.append(Entry(update: update, at: .now))
    }
}

private func withRelay(
    relayKnows: Bool, refusals: Int = 2, reason: String = "host offline",
    check: (RetryRelayServer, RetryUpdates, PhoneIdentity, QrPayload) async throws -> Void
) async throws {
    let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
    let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
    let host = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
    let identity = PhoneIdentity(signingPrivateKey: signing.rawRepresentation, signingPublicKey: signing.publicKey.rawRepresentation,
        sessionPrivateKey: device.rawRepresentation, sessionPublicKey: device.publicKey.rawRepresentation)
    let pairing = QrPayload(v: 3, relayUrl: "wss://relay.test", macPubkey: host.publicKey.rawRepresentation.base64URLEncodedString(),
        token: "retry-test-token", roomId: "retry-test-room", secret: Data(repeating: 4, count: 32).base64URLEncodedString())
    let server = try RetryRelayServer(refusals: refusals, reason: reason)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    let connection: RelayConnection
    do {
        let url = try await server.url()
        connection = RelayConnection(path: .relay, dial: url, pairing: pairing, identity: identity,
            relayKnows: relayKnows, local: PeerInfo(app: "test"), urlSession: session)
    } catch {
        session.invalidateAndCancel()
        await server.stop()
        throw error
    }
    let updates = RetryUpdates()
    let stream = await connection.updates()
    let collector = Task {
        for await update in stream { await updates.record(update) }
    }
    await connection.start()
    do {
        try await check(server, updates, identity, pairing)
    } catch {
        await connection.stop()
        collector.cancel()
        await collector.value
        session.invalidateAndCancel()
        await server.stop()
        throw error
    }
    await connection.stop()
    collector.cancel()
    await collector.value
    session.invalidateAndCancel()
    await server.stop()
}

// Mutable state and Network callbacks stay on this serial queue; snapshots cross it by continuation.
private final class RetryRelayServer: @unchecked Sendable {
    struct Join: Sendable {
        let message: [String: String]
        let nonce: String
        let accepted: Bool
        let at: ContinuousClock.Instant
    }

    struct Snapshot: Sendable {
        var port: UInt16?
        var errors: [String] = []
        var dials: [ContinuousClock.Instant] = []
        var joins: [Join] = []
    }

    private let queue = DispatchQueue(label: "RelayHostOfflineRetryTests.server")
    private let listener: NWListener
    private let refusals: Int
    private let reason: String
    private var connections: [NWConnection] = []
    private var stopped: Set<ObjectIdentifier> = []
    private var recorded = Snapshot()

    init(refusals: Int, reason: String) throws {
        self.refusals = refusals
        self.reason = reason
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: recorded.port = listener.port?.rawValue
            case .failed(let error): recorded.errors.append(String(describing: error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.recorded) }
        }
    }

    func url() async throws -> URL {
        try await eventually {
            let state = await self.snapshot()
            if let error = state.errors.first { throw RetryHarnessError.listener(error) }
            return state.port != nil
        }
        let state = await snapshot()
        let port = try #require(state.port)
        return try #require(URL(string: "ws://127.0.0.1:\(port)/"))
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.listener.cancel()
                for connection in self.connections {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                }
                self.connections.removeAll()
                continuation.resume()
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        recorded.dials.append(.now)
        connections.append(connection)
        let nonce = UUID().uuidString
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                send(Data("{\"type\":\"nonce\",\"nonce\":\"\(nonce)\"}".utf8), on: connection)
                receive(on: connection, nonce: nonce)
            } else if case .failed(let error) = state {
                record(error, on: connection)
                stopped.insert(ObjectIdentifier(connection))
            } else if case .cancelled = state {
                stopped.insert(ObjectIdentifier(connection))
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, nonce: String) {
        guard !stopped.contains(ObjectIdentifier(connection)) else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                record(error, on: connection)
                stopped.insert(ObjectIdentifier(connection))
                return
            }
            guard !stopped.contains(ObjectIdentifier(connection)) else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                stopped.insert(ObjectIdentifier(connection))
                return
            }
            guard metadata?.opcode == .text, let data else { return }
            do {
                let message = try JSONDecoder().decode([String: String].self, from: data)
                if message["type"] == "join" {
                    let accepted = recorded.joins.count >= refusals
                    recorded.joins.append(Join(message: message, nonce: nonce, accepted: accepted, at: .now))
                    if !accepted {
                        let close = NWProtocolWebSocket.Metadata(opcode: .close)
                        close.closeCode = .privateCode(4011)
                        send(Data(reason.utf8), on: connection, metadata: close)
                        return
                    }
                    let response = try JSONSerialization.data(withJSONObject: [
                        "type": "joined", "roomId": "retry-test-room", "ownerOnline": false,
                    ] as [String: Any])
                    send(response, on: connection)
                }
                receive(on: connection, nonce: nonce)
            } catch {
                recorded.errors.append(String(describing: error))
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection,
        metadata: NWProtocolWebSocket.Metadata = NWProtocolWebSocket.Metadata(opcode: .text)) {
        guard !stopped.contains(ObjectIdentifier(connection)) else { return }
        if metadata.opcode == .close { stopped.insert(ObjectIdentifier(connection)) }
        let context = NWConnection.ContentContext(identifier: "relay-test", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { self?.record(error, on: connection) }
        })
    }

    private func record(_ error: NWError, on connection: NWConnection) {
        if case .posix(let code) = error, [.ENOTCONN, .ECONNRESET, .ECANCELED].contains(code) {
            stopped.insert(ObjectIdentifier(connection))
            return
        }
        recorded.errors.append(String(describing: error))
    }
}
