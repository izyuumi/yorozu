import CryptoKit
import Foundation

/// Local Mac pairing (#532, feature flag `local-pair`): "Pair with the Gateway on this Mac" asks the plugin's loopback
/// direct listener where its local pairing file is. The client probes as on the direct path, but without a room yet: the
/// room is the hash of the key that answered. Then it sends `{"type":"local_pair"}` and gets
/// `{"type":"local_pair","path":…}`, or `error` when the host could not make a code. The link itself never crosses the
/// socket; the app reads it from the file (owner-only, `0600`) and checks it names the proven room.
public enum LocalPairing {
    /// The feature flag of the `local_pair` message. A plugin without it closes the socket (4101), which reads as no host.
    public static let flag = "local-pair"
    /// Per loopback address: the probe, the request and the host making a code.
    public static let timeout = Duration.seconds(5)

    public struct Found: Equatable, Sendable {
        /// The local pairing file's absolute path, as the plugin named it.
        public let path: String
        /// The room the probe proved: `base64url(sha256(signingKey))`.
        public let room: String
        /// The host's Ed25519 key, which signed the probe.
        public let signingKey: Data
    }

    public enum Failure: Error, Equatable, Sendable {
        /// No loopback listener proved a key and named a file.
        case notFound
        /// A host proved its key but could not make a pairing code.
        case hostFailed
    }

    /// Asks `ws://127.0.0.1:<port>`, then `ws://[::1]:<port>`.
    public static func find(port: Int = Direct.port, timeout: Duration = LocalPairing.timeout, urlSession: URLSession = .shared)
        async throws -> Found {
        try await find(urls: urls(port: port), timeout: timeout) { URLSessionPairingSocket(urlSession.webSocketTask(with: $0)) }
    }

    static func urls(port: Int) -> [URL] {
        ["127.0.0.1", "[::1]"].compactMap { URL(string: "ws://\($0):\(port)") }
    }

    static func find(urls: [URL], timeout: Duration, connect: @Sendable (URL) -> any LocalPairingSocket) async throws -> Found {
        var failure = Failure.notFound
        for url in urls {
            do {
                return try await ask(connect(url), timeout: timeout)
            } catch Failure.hostFailed {
                failure = .hostFailed
            } catch {}
        }
        throw failure
    }

    /// One listener, closed when it answered, failed or ran out of time.
    static func ask(_ socket: any LocalPairingSocket, timeout: Duration) async throws -> Found {
        try await withThrowingTaskGroup(of: Found.self) { group in
            group.addTask { try await exchange(socket) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.notFound
            }
            // Closing ends a `receive` still waiting, so the group can finish.
            defer {
                group.cancelAll()
                socket.close()
            }
            guard let found = try await group.next() else { throw Failure.notFound }
            return found
        }
    }

    static func exchange(_ socket: any LocalPairingSocket) async throws -> Found {
        let nonce = Direct.newNonce()
        try await socket.send(text(["type": "probe", "nonce": nonce]))
        let answer = try await object(socket.receive())
        guard answer["type"] as? String == "probe", let pubkey = answer["pubkey"] as? String, let sig = answer["sig"] as? String,
              let room = verify(nonce: nonce, pubkey: pubkey, sig: sig), let key = Data(base64URLEncoded: pubkey) else {
            throw Failure.notFound
        }
        try await socket.send(text(["type": "local_pair"]))
        let reply = try await object(socket.receive())
        guard reply["type"] as? String == "local_pair" else { throw Failure.notFound }
        guard let path = reply["path"] as? String, path.hasPrefix("/") else { throw Failure.hostFailed }
        return Found(path: path, room: room, signingKey: key)
    }

    /// The probe answer when the client knows no room yet: the room is the answered key's hash, and that key must have
    /// signed the nonce for it. The room, or nil.
    public static func verify(nonce: String, pubkey: String, sig: String) -> String? {
        guard let key = Data(base64URLEncoded: pubkey), key.count == 32 else { return nil }
        let room = Data(SHA256.hash(data: key)).base64URLEncodedString()
        return Direct.verifyProbe(room: room, nonce: nonce, pubkey: pubkey, sig: sig) ? room : nil
    }

    private static func text(_ message: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    }

    private static func object(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw Failure.notFound }
        return object
    }
}

/// What local pairing uses of a WebSocket; tests script one.
protocol LocalPairingSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    /// Ends the socket; a `receive` waiting then throws.
    func close()
}

struct URLSessionPairingSocket: LocalPairingSocket {
    let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 64 << 10
        task.resume()
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        guard case .string(let text) = try await task.receive() else { throw LocalPairing.Failure.notFound }
        return text
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}
