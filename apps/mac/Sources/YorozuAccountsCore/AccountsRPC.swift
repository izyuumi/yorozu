import Foundation

@MainActor public final class AccountsRPC {
    public nonisolated static let maximumLineBytes = AccountSnapshot.maximumBytes + 16_384
    private let service: AccountService
    public init(service: AccountService) { self.service = service }
    public func close() { service.close() }
    public func reply(to data: Data) -> Data {
        var rid = "invalid"
        do {
            let request = try AccountJSON.decode(data, limit: Self.maximumLineBytes)
            guard let object = request.object else { throw AccountError.invalid }
            if let valid = object["rid"]?.string, accountBinding(valid) { rid = valid }
            guard accountFields(object, required: ["version", "rid", "command"], optional: ["payload"]),
                object["version"]?.integer == 1, accountBinding(object["rid"]?.string), let command = object["command"]?.string,
                command.utf8.count <= 32 else { throw AccountError.invalid }
            let value = try service.perform(command, payload: object["payload"])
            return encode(["version": .number(1), "rid": .string(rid), "ok": .bool(true), "value": value])
        } catch {
            let code = (error as? AccountError) ?? .unknown
            return encode(["version": .number(1), "rid": .string(rid), "ok": .bool(false), "error": .string(code.rawValue)])
        }
    }
    private func encode(_ reply: [String: AccountJSON]) -> Data {
        // All errors are closed enums. Native descriptions, URLs, and secrets never enter diagnostics.
        (try? AccountJSON.object(reply).encoded()) ?? Data(#"{"version":1,"rid":"invalid","ok":false,"error":"unknown"}"#.utf8)
    }
}

public struct AccountLineReader {
    public enum Frame { case line(Data), invalid }
    private var pending = Data()
    private var oversized = false
    public let limit: Int
    public init(limit: Int = AccountsRPC.maximumLineBytes) { self.limit = max(1, limit) }
    /// The executable reads at most 4096 bytes per call; pending allocation never exceeds limit.
    public mutating func accept(_ bytes: Data) -> [Frame] {
        var frames: [Frame] = []
        for byte in bytes {
            if byte == 10 {
                frames.append(oversized ? .invalid : .line(pending))
                pending = Data(); oversized = false
            } else if !oversized {
                if pending.count == limit { pending = Data(); oversized = true }
                else { pending.append(byte) }
            }
        }
        return frames
    }
    public mutating func finish() -> Frame? {
        defer { pending = Data(); oversized = false }
        if oversized { return .invalid }
        return pending.isEmpty ? nil : .line(pending)
    }
    public var bufferedBytes: Int { pending.count }
}
