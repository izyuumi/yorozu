import CryptoKit
import Foundation
import Testing
@testable import YorozuWire

/// A socket whose host answers each sent message from a script; `close` ends a waiting `receive`.
final class ScriptedSocket: LocalPairingSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var sentTexts: [String] = []
    private var isClosed = false
    private let answer: @Sendable (String) -> [String]

    init(answer: @escaping @Sendable (String) -> [String]) { self.answer = answer }

    var sent: [[String: Any]] {
        lock.withLock { sentTexts }.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
    var closed: Bool { lock.withLock { isClosed } }

    func send(_ text: String) async throws {
        lock.withLock { sentTexts.append(text) }
        for reply in answer(text) { deliver(reply) }
    }

    private func deliver(_ text: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            queue.append(text)
            lock.unlock()
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let text = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: text)
            } else if isClosed {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        isClosed = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }
}

/// The local Mac pairing exchange (#532 `local-pair`): the probe without a known room, then `local_pair`.
struct LocalPairingTests {
    let host = Curve25519.Signing.PrivateKey()
    var pubkey: String { host.publicKey.rawRepresentation.base64URLEncodedString() }
    var room: String { Data(SHA256.hash(data: host.publicKey.rawRepresentation)).base64URLEncodedString() }

    static func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    static func string(_ object: [String: String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A host that signs with `signer` (the room's key unless given) and answers `local_pair` with `reply`.
    func scripted(signer: Curve25519.Signing.PrivateKey? = nil, reply: [String: String]? = ["type": "local_pair", "path": "/state/yorozu/local-pairing"])
        -> ScriptedSocket {
        let signer = signer ?? host
        let (key, roomID) = (pubkey, room)
        return ScriptedSocket { text in
            let message = Self.json(text)
            switch message["type"] as? String {
            case "probe":
                let nonce = message["nonce"] as? String ?? ""
                let sig = (try? signer.signature(for: Data("yorozu-direct|\(roomID)|\(nonce)".utf8)))?.base64URLEncodedString() ?? ""
                return [Self.string(["type": "probe", "pubkey": key, "sig": sig])]
            case "local_pair":
                return reply.map { [Self.string($0)] } ?? []
            default:
                return []
            }
        }
    }

    @Test func theProbeProvesARoomTheClientDidNotKnow() throws {
        let nonce = Direct.newNonce()
        let sig = try host.signature(for: Data("yorozu-direct|\(room)|\(nonce)".utf8)).base64URLEncodedString()
        #expect(LocalPairing.verify(nonce: nonce, pubkey: pubkey, sig: sig) == room)
        #expect(LocalPairing.verify(nonce: Direct.newNonce(), pubkey: pubkey, sig: sig) == nil, "another nonce")
        let other = Curve25519.Signing.PrivateKey()
        let forged = try other.signature(for: Data("yorozu-direct|\(room)|\(nonce)".utf8)).base64URLEncodedString()
        #expect(LocalPairing.verify(nonce: nonce, pubkey: pubkey, sig: forged) == nil, "signed by another key")
        #expect(LocalPairing.verify(nonce: nonce, pubkey: "short", sig: sig) == nil)
    }

    @Test func aProvenHostNamesItsFile() async throws {
        let socket = scripted()
        let found = try await LocalPairing.ask(socket, timeout: .seconds(5))
        #expect(found == LocalPairing.Found(path: "/state/yorozu/local-pairing", room: room, signingKey: host.publicKey.rawRepresentation))
        let sent = socket.sent
        #expect(sent.count == 2)
        #expect(sent.first?["type"] as? String == "probe")
        #expect(Data(base64URLEncoded: sent.first?["nonce"] as? String ?? "")?.count == 32)
        #expect(sent.last?["type"] as? String == "local_pair")
        #expect(sent.last?.count == 1)
        #expect(socket.closed)
    }

    @Test func anUnprovenHostGetsNoRequest() async {
        let socket = scripted(signer: Curve25519.Signing.PrivateKey())
        await #expect(throws: LocalPairing.Failure.notFound) { try await LocalPairing.ask(socket, timeout: .seconds(5)) }
        #expect(socket.sent.count == 1, "only the probe")
    }

    @Test func aHostThatCouldNotMakeACodeSaysSo() async {
        await #expect(throws: LocalPairing.Failure.hostFailed) {
            try await LocalPairing.ask(scripted(reply: ["type": "local_pair", "error": "the host could not make a pairing code"]), timeout: .seconds(5))
        }
        await #expect(throws: LocalPairing.Failure.hostFailed, "a relative path") {
            try await LocalPairing.ask(scripted(reply: ["type": "local_pair", "path": "local-pairing"]), timeout: .seconds(5))
        }
    }

    @Test func aSilentListenerTimesOutAndIsClosed() async {
        let silent = scripted(reply: nil)
        let start = ContinuousClock.now
        await #expect(throws: LocalPairing.Failure.notFound) { try await LocalPairing.ask(silent, timeout: .milliseconds(100)) }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(silent.closed)
    }

    @Test func itTriesIPv4LoopbackThenIPv6() async throws {
        #expect(LocalPairing.urls(port: 8738).map(\.absoluteString) == ["ws://127.0.0.1:8738", "ws://[::1]:8738"])
        let (silent, good) = (scripted(reply: nil), scripted())
        let found = try await LocalPairing.find(urls: LocalPairing.urls(port: 8738), timeout: .milliseconds(100)) { url in
            url.host() == "127.0.0.1" ? silent : good
        }
        #expect(found.room == room)
        let failing = scripted(reply: ["type": "local_pair", "error": "x"])
        await #expect(throws: LocalPairing.Failure.hostFailed, "a host that answered beats one that didn't") {
            try await LocalPairing.find(urls: LocalPairing.urls(port: 8738), timeout: .milliseconds(100)) { url in
                url.host() == "127.0.0.1" ? failing : silent
            }
        }
    }
}
