import Foundation

@MainActor public protocol AccountProtectedBackend: AnyObject {
    func available() -> Bool
    func read() throws -> Data?
    func create(_ data: Data) throws
    func replace(_ data: Data) throws
}
@MainActor public protocol AccountLockBackend: AnyObject {
    func acquireGlobal() throws -> () -> Void
    func acquireAccount(_ binding: String) throws -> () -> Void
}
@MainActor public protocol AccountBrowser: AnyObject {
    func open(_ url: URL) -> Bool
}

/// Trusted host pipes only. No generic native tool dispatch, storage path, or credential input source.
@MainActor public final class AccountService {
    private let backend: any AccountProtectedBackend
    private let locks: any AccountLockBackend
    private let browser: any AccountBrowser
    private let hostId: () -> String
    private let leaseId: () -> String
    private var identity: String?
    private var leases: [String: (String, () -> Void)] = [:]
    private var closed = false
    public init(backend: any AccountProtectedBackend, locks: any AccountLockBackend, browser: any AccountBrowser,
        hostId: @escaping () -> String = { UUID().uuidString.lowercased() },
        leaseId: @escaping () -> String = { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined() }) {
        self.backend = backend; self.locks = locks; self.browser = browser; self.hostId = hostId; self.leaseId = leaseId
    }
    public func close() {
        guard !closed else { return }; closed = true
        for (_, release) in leases.values { release() }; leases.removeAll()
    }
    public func perform(_ command: String, payload: AccountJSON?) throws -> AccountJSON {
        guard !closed else { throw AccountError.unsupported }
        switch command {
        case "available":
            try empty(payload); return .bool(backend.available())
        case "initialize":
            let p = try fields(payload, required: ["appName"])
            guard p["appName"]?.string == "Yorozu" else { throw AccountError.invalid }
            return try globally {
                if let existing = try backend.read() { return try checked(existing).value }
                let snapshot = try AccountSnapshot.initial(hostId: hostId())
                try backend.create(snapshot.value.encoded()); identity = snapshot.hostId
                return snapshot.value
            }
        case "read":
            try empty(payload); return try globally { try current().value }
        case "replace":
            let p = try fields(payload, required: ["expectedRevision", "next"])
            guard let expected = p["expectedRevision"]?.integer else { throw AccountError.invalid }
            let next = try AccountSnapshot(value: p["next"]!)
            guard expected < 9_007_199_254_740_990, next.revision == expected + 1 else { throw AccountError.invalid }
            return try globally {
                let before = try current()
                guard next.hostId == before.hostId else { throw AccountError.invalid }
                guard before.revision == expected else { return .string("conflict") }
                // This protocol has no destructive cleanup or identity-migration command.
                // Sign-out retains established binding/client/subject identity.
                for existing in before.accounts {
                    guard let replacement = next.accounts.first(where: {
                        $0.object?["accountBindingId"] == existing.object?["accountBindingId"]
                    }) else { throw AccountError.invalid }
                    if let registration = existing.object?["registration"], replacement.object?["registration"] != registration {
                        throw AccountError.invalid
                    }
                }
                try backend.replace(next.value.encoded())
                return .string("committed")
            }
        case "lock":
            let p = try fields(payload, required: ["accountBindingId"])
            guard let binding = p["accountBindingId"]?.string, accountBinding(binding) else { throw AccountError.invalid }
            guard leases.count < 32, !leases.values.contains(where: { $0.0 == binding }) else { throw AccountError.conflict }
            let lease = leaseId()
            guard accountPattern(lease, #"^[a-f0-9]{64}$"#), leases[lease] == nil else { throw AccountError.unknown }
            let release = try locks.acquireAccount(binding)
            leases[lease] = (binding, release)
            return .string(lease)
        case "unlock":
            let p = try fields(payload, required: ["lease"])
            guard let lease = p["lease"]?.string, accountPattern(lease, #"^[a-f0-9]{64}$"#), let held = leases.removeValue(forKey: lease) else { throw AccountError.invalid }
            held.1(); return .bool(true)
        case "open-browser":
            let p = try fields(payload, required: ["authorizationUrl"])
            guard let raw = p["authorizationUrl"]?.string else { throw AccountError.invalid }
            let snapshot = try globally { try current() }
            let url = try AccountAuthorizationURL.validate(raw, snapshot: snapshot)
            return .object(["opened": .bool(browser.open(url))])
        default: throw AccountError.unsupported
        }
    }
    private func checked(_ data: Data) throws -> AccountSnapshot {
        let snapshot = try AccountSnapshot(data: data)
        if let identity, identity != snapshot.hostId { throw AccountError.invalid }
        identity = snapshot.hostId; return snapshot
    }
    private func current() throws -> AccountSnapshot {
        guard let data = try backend.read() else { throw AccountError.unsupported }; return try checked(data)
    }
    private func globally<T>(_ body: () throws -> T) throws -> T {
        let release = try locks.acquireGlobal(); defer { release() }
        return try body()
    }
    private func fields(_ value: AccountJSON?, required: Set<String>) throws -> [String: AccountJSON] {
        guard let object = value?.object, accountFields(object, required: required) else { throw AccountError.invalid }; return object
    }
    private func empty(_ value: AccountJSON?) throws {
        guard value == nil || value == .object([:]) else { throw AccountError.invalid }
    }
}

enum AccountAuthorizationURL {
    static func validate(_ raw: String, snapshot: AccountSnapshot) throws -> URL {
        guard raw.utf8.count <= 65_536, raw.hasPrefix("https://auth.openai.com/api/accounts/authorize?"),
            let c = URLComponents(string: raw), c.scheme == "https", c.percentEncodedHost == "auth.openai.com",
            c.port == nil, c.user == nil, c.password == nil, c.fragment == nil, c.percentEncodedPath == "/api/accounts/authorize",
            let items = c.queryItems, Set(items.map(\.name)).count == items.count, items.allSatisfy({ $0.value != nil }) else { throw AccountError.invalid }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, AccountJSON.string($0.value!)) })
        guard accountFields(query, required: ["client_id", "ext_agent_host_id", "response_type", "redirect_uri", "scope", "resource", "state", "nonce", "code_challenge_method", "code_challenge"], optional: ["agent_name_hint", "id_token_hint"]),
            query["ext_agent_host_id"]?.string == snapshot.hostId, query["response_type"]?.string == "code",
            query["resource"]?.string == "https://api.openai.com/v1", query["code_challenge_method"]?.string == "S256",
            ["state", "nonce", "code_challenge"].allSatisfy({ accountPattern(query[$0]?.string, #"^[A-Za-z0-9_-]{43}$"#) }),
            let scope = query["scope"]?.string, scope.utf8.count <= 512 else { throw AccountError.invalid }
        let scopes = scope.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard Set(scopes) == AccountSnapshot.scopes, scopes.count == AccountSnapshot.scopes.count,
            let redirect = query["redirect_uri"]?.string, let callback = URLComponents(string: redirect),
            callback.scheme == "http", callback.percentEncodedHost == "127.0.0.1", let port = callback.port,
            (1024...65535).contains(port), callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil,
            callback.percentEncodedPath == "/auth/callback", redirect == "http://127.0.0.1:\(port)/auth/callback" else { throw AccountError.invalid }
        if query["client_id"]?.string == "dynamic_agent_client" {
            guard query["agent_name_hint"]?.string == "Yorozu", query["id_token_hint"] == nil else { throw AccountError.invalid }
        } else {
            guard accountClient(query["client_id"]?.string), query["agent_name_hint"] == nil,
                let registered = snapshot.accounts.first(where: { $0.object?["registration"]?.object?["clientId"] == query["client_id"] }) else { throw AccountError.invalid }
            if let hint = query["id_token_hint"] {
                guard accountSecret(hint.string), registered.object?["credentials"]?.object?["idToken"] == hint else { throw AccountError.invalid }
            }
        }
        guard let url = c.url, url.absoluteString == raw else { throw AccountError.invalid }; return url
    }
}
