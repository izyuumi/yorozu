import Foundation

public struct AccountSnapshot: Equatable, Sendable {
    public static let maximumBytes = 1_048_576
    public let value: AccountJSON
    public var object: [String: AccountJSON] { value.object! }
    public var revision: Int { object["revision"]!.integer! }
    public var hostId: String { object["hostId"]!.string! }
    public var accounts: [AccountJSON] { object["accounts"]!.array! }
    public init(value: AccountJSON) throws {
        guard let v = value.object, accountFields(v, required: ["version", "revision", "hostId", "appName", "callbackPath", "accounts"], optional: ["activeAccountBindingId"]),
            v["version"]?.integer == 1, let revision = v["revision"]?.integer, revision < 9_007_199_254_740_991,
            accountBinding(v["hostId"]?.string), v["appName"]?.string == "Yorozu", v["callbackPath"]?.string == "/auth/callback",
            let accounts = v["accounts"]?.array, accounts.count <= 32, accounts.allSatisfy(Self.validAccount),
            Set(accounts.compactMap { $0.object?["accountBindingId"]?.string }).count == accounts.count else { throw AccountError.invalid }
        let clients = accounts.compactMap { $0.object?["registration"]?.object?["clientId"]?.string }
        guard Set(clients).count == clients.count else { throw AccountError.invalid }
        if let active = v["activeAccountBindingId"] {
            guard accountBinding(active.string), accounts.contains(where: { $0.object?["accountBindingId"] == active }) else { throw AccountError.invalid }
        }
        guard try value.encoded().count <= Self.maximumBytes else { throw AccountError.invalid }
        self.value = value
    }
    public init(data: Data) throws { try self.init(value: AccountJSON.decode(data, limit: Self.maximumBytes)) }
    public static func initial(hostId: String) throws -> AccountSnapshot {
        try AccountSnapshot(value: .object(["version": .number(1), "revision": .number(0), "hostId": .string(hostId),
            "appName": .string("Yorozu"), "callbackPath": .string("/auth/callback"), "accounts": .array([])]))
    }
    static let scopes: Set<String> = ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    static func validScopes(_ value: AccountJSON?) -> Bool {
        guard let values = value?.array, values.count <= 6 else { return false }
        let strings = values.compactMap(\.string)
        return strings.count == values.count && Set(strings).count == strings.count && Set(strings).isSubset(of: scopes)
    }
    static func validCredentials(_ value: AccountJSON) -> Bool {
        guard let v = value.object, accountFields(v, required: ["accessToken", "idToken", "expiresAt"], optional: ["refreshToken", "earliestRefreshAt"]),
            accountSecret(v["accessToken"]?.string), accountSecret(v["idToken"]?.string), v["expiresAt"]?.integer != nil else { return false }
        return (v["refreshToken"] == nil || accountSecret(v["refreshToken"]?.string))
            && (v["earliestRefreshAt"] == nil || v["earliestRefreshAt"]?.integer != nil)
    }
    static func validAccount(_ value: AccountJSON) -> Bool {
        guard let v = value.object, accountFields(v, required: ["accountBindingId", "phase", "scopes"], optional: ["registration", "credentials", "pending", "remoteRevocation"]),
            accountBinding(v["accountBindingId"]?.string), let phase = v["phase"]?.string,
            ["ready", "signed-out", "exchanging", "refreshing", "pending-verification", "revoking"].contains(phase), validScopes(v["scopes"]) else { return false }
        if let registration = v["registration"] {
            guard let r = registration.object, accountFields(r, required: ["clientId", "subject"]), accountClient(r["clientId"]?.string),
                accountPattern(r["subject"]?.string, #"^[A-Za-z0-9_.:@|\-]{1,256}$"#) else { return false }
        }
        if let credentials = v["credentials"], !validCredentials(credentials) { return false }
        if let revocation = v["remoteRevocation"], !["confirmed", "unconfirmed"].contains(revocation.string ?? "") { return false }
        if let pending = v["pending"] {
            guard let p = pending.object, accountFields(p, required: ["kind", "operationId", "clientId"], optional: ["nonce", "credentials", "scopes"]),
                ["sign-in", "refresh"].contains(p["kind"]?.string ?? ""), accountPattern(p["operationId"]?.string, #"^[a-f0-9]{64}$"#),
                accountClient(p["clientId"]?.string), (p["nonce"] == nil || accountSecret(p["nonce"]?.string)),
                (p["credentials"] == nil || validCredentials(p["credentials"]!)), (p["scopes"] == nil || validScopes(p["scopes"])) else { return false }
        }
        if phase == "ready" || phase == "signed-out" {
            return v["pending"] == nil && (phase == "ready" ? v["registration"] != nil && v["credentials"] != nil
                && v["scopes"]!.array!.contains(.string("openid")) : v["credentials"] == nil)
        }
        if phase == "revoking" { return v["registration"] != nil && v["pending"] == nil }
        guard let p = v["pending"]?.object else { return false }
        if phase == "refreshing", v["registration"] == nil || p["kind"]?.string != "refresh" { return false }
        if let r = v["registration"]?.object, r["clientId"] != p["clientId"] { return false }
        if p["kind"]?.string == "sign-in", !accountSecret(p["nonce"]?.string) { return false }
        return phase == "pending-verification" ? p["credentials"] != nil && p["scopes"]?.array?.contains(.string("openid")) == true : p["credentials"] == nil
    }
}
