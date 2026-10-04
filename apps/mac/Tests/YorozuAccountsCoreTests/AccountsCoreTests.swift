import Foundation
import Testing
@testable import YorozuAccountsCore

@MainActor private final class MemoryBackend: AccountProtectedBackend {
    var data: Data?
    var reads = 0, creates = 0, writes = 0
    var accessible = true
    var uncertainWrite = false
    var readFailure = false
    func available() -> Bool { accessible }
    func read() throws -> Data? {
        reads += 1
        if readFailure { throw NSError(domain: "synthetic-token-that-must-never-be-logged", code: 42) }
        return data
    }
    func create(_ data: Data) throws {
        creates += 1; guard self.data == nil else { throw AccountError.conflict }; self.data = data
    }
    func replace(_ data: Data) throws {
        writes += 1; self.data = data
        if uncertainWrite { throw NSError(domain: "synthetic-refresh-token-that-must-never-be-logged", code: 43) }
    }
}
@MainActor private final class FakeLocks: AccountLockBackend {
    var global = false
    var accounts = Set<String>()
    var acquisitions = 0
    func acquireGlobal() throws -> () -> Void {
        guard !global else { throw AccountError.conflict }; global = true; acquisitions += 1
        return { self.global = false }
    }
    func acquireAccount(_ binding: String) throws -> () -> Void {
        guard accounts.insert(binding).inserted else { throw AccountError.conflict }; acquisitions += 1
        return { self.accounts.remove(binding) }
    }
}
@MainActor private final class FakeBrowser: AccountBrowser {
    var opened: [URL] = []
    func open(_ url: URL) -> Bool { opened.append(url); return true }
}
@MainActor private final class Fixture {
    let backend = MemoryBackend(), locks = FakeLocks(), browser = FakeBrowser()
    var sequence = 0
    func service() -> AccountService {
        AccountService(backend: backend, locks: locks, browser: browser, hostId: { "synthetic-stable-host" },
            leaseId: { self.sequence += 1; return String(format: "%064x", self.sequence) })
    }
    func initialized() throws -> (AccountService, AccountSnapshot) {
        let service = service()
        let value = try service.perform("initialize", payload: .object(["appName": .string("Yorozu")]))
        return (service, try AccountSnapshot(value: value))
    }
}
private func next(_ snapshot: AccountSnapshot, changes: [String: AccountJSON] = [:]) -> AccountJSON {
    var object = snapshot.object; object["revision"] = .number(Double(snapshot.revision + 1))
    for (key, value) in changes { object[key] = value }; return .object(object)
}
@MainActor private func replace(_ service: AccountService, before: AccountSnapshot, value: AccountJSON) throws -> AccountJSON {
    try service.perform("replace", payload: .object(["expectedRevision": .number(Double(before.revision)), "next": value]))
}
private func signedOut(_ binding: String = "account-a") -> AccountJSON {
    .object(["accountBindingId": .string(binding), "phase": .string("signed-out"), "scopes": .array([])])
}
private func authorization(host: String = "synthetic-stable-host") -> String {
    var c = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
    c.queryItems = [
        .init(name: "client_id", value: "dynamic_agent_client"), .init(name: "ext_agent_host_id", value: host),
        .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: "http://127.0.0.1:54000/auth/callback"),
        .init(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
        .init(name: "resource", value: "https://api.openai.com/v1"), .init(name: "state", value: String(repeating: "s", count: 43)),
        .init(name: "nonce", value: String(repeating: "n", count: 43)), .init(name: "code_challenge_method", value: "S256"),
        .init(name: "code_challenge", value: String(repeating: "c", count: 43)), .init(name: "agent_name_hint", value: "Yorozu"),
    ]; return c.string!
}

@MainActor @Test func protectedAccountInitializationIsInertStableAndIdempotent() throws {
    let f = Fixture(), service = f.service()
    #expect(f.backend.reads == 0 && f.locks.acquisitions == 0 && f.browser.opened.isEmpty)
    #expect(try service.perform("available", payload: nil) == .bool(true))
    #expect(f.backend.reads == 0 && f.locks.acquisitions == 0)
    let p: AccountJSON = .object(["appName": .string("Yorozu")])
    let initial = try service.perform("initialize", payload: p)
    #expect(try AccountSnapshot(value: initial).revision == 0)
    #expect(try service.perform("initialize", payload: p) == initial)
    let other = f.service()
    #expect(try other.perform("initialize", payload: p) == initial)
    #expect(f.backend.creates == 1 && !f.locks.global)
    #expect(throws: AccountError.invalid) { try service.perform("initialize", payload: .object(["appName": .string("Foreign")])) }
    #expect(throws: AccountError.invalid) { try service.perform("initialize", payload: .object(["appName": .string("Yorozu"), "path": .string("/private")])) }
}

@MainActor @Test func protectedAccountCASExcludesOtherWritersAndPreservesIdentity() throws {
    let f = Fixture(), (service, initial) = try f.initialized()
    let replacement = next(initial, changes: ["accounts": .array([signedOut()])])
    #expect(try replace(service, before: initial, value: replacement) == .string("committed"))
    #expect(try replace(f.service(), before: initial, value: replacement) == .string("conflict"))
    #expect(f.backend.writes == 1)
    let current = try AccountSnapshot(value: service.perform("read", payload: nil))
    #expect(throws: AccountError.invalid) { try replace(service, before: current, value: next(current, changes: ["hostId": .string("foreign-host")])) }
    #expect(throws: AccountError.invalid) { try replace(service, before: current, value: next(current, changes: ["callbackPath": .string("/elsewhere")])) }
    f.locks.global = true
    #expect(throws: AccountError.conflict) { try service.perform("read", payload: nil) }
    f.locks.global = false
    #expect(f.backend.writes == 1)
    f.backend.data = try AccountSnapshot.initial(hostId: "foreign-host").value.encoded()
    #expect(throws: AccountError.invalid) { try service.perform("read", payload: nil) }
}

@MainActor @Test func protectedAccountLeasesHaveExactOwnerAndCloseReleasesAll() throws {
    let f = Fixture(), service = f.service(), other = f.service()
    let payload: AccountJSON = .object(["accountBindingId": .string("account-a")])
    let lease = try service.perform("lock", payload: payload)
    #expect(lease.string?.count == 64)
    #expect(throws: AccountError.conflict) { try other.perform("lock", payload: payload) }
    #expect(throws: AccountError.invalid) { try other.perform("unlock", payload: .object(["lease": lease])) }
    #expect(try service.perform("unlock", payload: .object(["lease": lease])) == .bool(true))
    _ = try other.perform("lock", payload: payload)
    _ = try other.perform("lock", payload: .object(["accountBindingId": .string("account-b")]))
    #expect(f.locks.accounts.count == 2)
    other.close(); other.close()
    #expect(f.locks.accounts.isEmpty)
    #expect(throws: AccountError.unsupported) { try other.perform("available", payload: nil) }
    #expect(throws: AccountError.invalid) { try service.perform("lock", payload: .object(["accountBindingId": .string("../escape")])) }
    service.close()
}

@MainActor @Test func nativeAccountRPCErrorsAreBoundedAndNeverDiscloseBackendDescriptions() throws {
    let f = Fixture(), (service, _) = try f.initialized(), rpc = AccountsRPC(service: service)
    func reply(_ command: String, payload: AccountJSON? = nil) throws -> AccountJSON {
        var q: [String: AccountJSON] = ["version": .number(1), "rid": .string("request-1"), "command": .string(command)]
        q["payload"] = payload
        return try AccountJSON.decode(rpc.reply(to: AccountJSON.object(q).encoded()), limit: AccountsRPC.maximumLineBytes)
    }
    f.backend.readFailure = true
    let failed = try reply("read")
    #expect(failed == .object(["version": .number(1), "rid": .string("request-1"), "ok": .bool(false), "error": .string("unknown")]))
    #expect(!String(decoding: try failed.encoded(), as: UTF8.self).contains("synthetic-token"))
    #expect(try reply("unsupported-command").object?["error"] == .string("unsupported"))
    let duplicate = Data(#"{"version":1,"rid":"a","command":"read","command":"available"}"#.utf8)
    #expect(try AccountJSON.decode(rpc.reply(to: duplicate), limit: 4096).object?["error"] == .string("invalid"))
    let bad = Data(#"{"version":1,"rid":"a","command":"available","payload":null}"#.utf8)
    #expect(try AccountJSON.decode(rpc.reply(to: bad), limit: 4096).object?["rid"] == .string("a"))
    rpc.close()
}

@MainActor @Test func uncertainAccountCommitIsNotRetriedOrClaimedCommitted() throws {
    let f = Fixture(), (service, initial) = try f.initialized()
    f.backend.uncertainWrite = true
    let rpc = AccountsRPC(service: service)
    let request: AccountJSON = .object(["version": .number(1), "rid": .string("save"), "command": .string("replace"),
        "payload": .object(["expectedRevision": .number(0), "next": next(initial, changes: ["accounts": .array([signedOut()])])])])
    let response = try AccountJSON.decode(rpc.reply(to: request.encoded()), limit: 4096)
    #expect(response.object?["error"] == .string("unknown"))
    #expect(f.backend.writes == 1 && !f.locks.global)
    #expect(try AccountSnapshot(data: #require(f.backend.data)).revision == 1)
    rpc.close()
}

@MainActor @Test func accountBrowserAcceptsOnlySnapshotBoundOfficialAuthorization() throws {
    let f = Fixture(), (service, _) = try f.initialized()
    #expect(try service.perform("open-browser", payload: .object(["authorizationUrl": .string(authorization())])) == .object(["opened": .bool(true)]))
    for invalid in [authorization(host: "foreign"), authorization().replacingOccurrences(of: "auth.openai.com", with: "evil.example"),
        authorization() + "&state=duplicate", authorization() + "&client_secret=secret", authorization() + "#fragment",
        authorization().replacingOccurrences(of: "dynamic_agent_client", with: "oaiapp_unregistered"),
        authorization().replacingOccurrences(of: "127.0.0.1", with: "localhost")] {
        #expect(throws: AccountError.invalid) { try service.perform("open-browser", payload: .object(["authorizationUrl": .string(invalid)])) }
    }
    #expect(f.browser.opened.count == 1)
    service.close()
}

@MainActor @Test func protectedAccountSnapshotPreservesQuarantinedCredentialsAndReturningIdentity() throws {
    let f = Fixture(), (service, initial) = try f.initialized()
    let credentials: AccountJSON = .object(["accessToken": .string("synthetic_access_token_123456"),
        "refreshToken": .string("synthetic_refresh_token_123456"), "idToken": .string("synthetic_id_token_123456"), "expiresAt": .number(3_600_000)])
    let pending: AccountJSON = .object(["kind": .string("sign-in"), "operationId": .string(String(repeating: "a", count: 64)),
        "clientId": .string("oaiapp_synthetic"), "nonce": .string(String(repeating: "n", count: 43)),
        "credentials": credentials, "scopes": .array([.string("openid")])])
    let quarantined: AccountJSON = .object(["accountBindingId": .string("account-a"), "phase": .string("pending-verification"),
        "scopes": .array([]), "pending": pending])
    #expect(try replace(service, before: initial, value: next(initial, changes: ["accounts": .array([quarantined])])) == .string("committed"))
    let saved = try AccountSnapshot(value: service.perform("read", payload: nil))
    #expect(saved.accounts == [quarantined])
    let ready: AccountJSON = .object(["accountBindingId": .string("account-a"), "phase": .string("ready"),
        "registration": .object(["clientId": .string("oaiapp_synthetic"), "subject": .string("synthetic-subject")]),
        "scopes": .array([.string("openid")]), "credentials": credentials])
    #expect(try replace(service, before: saved, value: next(saved, changes: ["accounts": .array([ready]), "activeAccountBindingId": .string("account-a")])) == .string("committed"))
    var c = URLComponents(string: authorization())!
    c.queryItems = c.queryItems!.filter { $0.name != "agent_name_hint" }.map {
        $0.name == "client_id" ? URLQueryItem(name: $0.name, value: "oaiapp_synthetic") : $0
    }
    c.queryItems!.append(.init(name: "id_token_hint", value: credentials.object!["idToken"]!.string!))
    #expect(try service.perform("open-browser", payload: .object(["authorizationUrl": .string(c.string!)])) == .object(["opened": .bool(true)]))
    c.queryItems = c.queryItems!.map { $0.name == "id_token_hint" ? .init(name: $0.name, value: "synthetic_foreign_id_token_123456") : $0 }
    #expect(throws: AccountError.invalid) { try service.perform("open-browser", payload: .object(["authorizationUrl": .string(c.string!)])) }
    #expect(f.browser.opened.count == 1)
    let registered = try AccountSnapshot(value: service.perform("read", payload: nil))
    #expect(throws: AccountError.invalid) { try replace(service, before: registered, value: next(registered, changes: ["accounts": .array([])])) }
    var rebound = ready.object!
    rebound["registration"] = .object(["clientId": .string("oaiapp_foreign"), "subject": .string("synthetic-subject")])
    #expect(throws: AccountError.invalid) { try replace(service, before: registered, value: next(registered, changes: ["accounts": .array([.object(rebound)])])) }
    let signedOut: AccountJSON = .object(["accountBindingId": .string("account-a"), "phase": .string("signed-out"),
        "scopes": .array([]), "registration": ready.object!["registration"]!])
    #expect(try replace(service, before: registered, value: next(registered, changes: ["accounts": .array([signedOut])])) == .string("committed"))
    service.close()
}

@MainActor @Test func nativeAccountLeaseBudgetIsBoundedAndCleanupReleasesEveryFakeLock() throws {
    let f = Fixture(), service = f.service()
    for index in 0..<32 { _ = try service.perform("lock", payload: .object(["accountBindingId": .string("account-\(index)")])) }
    #expect(throws: AccountError.conflict) { try service.perform("lock", payload: .object(["accountBindingId": .string("extra-account")])) }
    #expect(f.locks.accounts.count == 32)
    service.close()
    #expect(f.locks.accounts.isEmpty)
}

@Test func nativeAccountLineReaderBoundsBeforeAllocationAndRecoversOnNextLine() throws {
    var reader = AccountLineReader(limit: 8)
    #expect(reader.accept(Data("12345678".utf8)).isEmpty && reader.bufferedBytes == 8)
    #expect(reader.accept(Data(repeating: 65, count: 4096)).isEmpty && reader.bufferedBytes == 0)
    let frames = reader.accept(Data("\n{}\n".utf8))
    #expect(frames.count == 2)
    if case .invalid = frames[0] {} else { Issue.record("Oversized frame was not rejected") }
    if case .line(let data) = frames[1] { #expect(data == Data("{}".utf8)) } else { Issue.record("Lost following frame") }
    #expect(reader.finish() == nil)
    _ = reader.accept(Data("123456789".utf8))
    if case .invalid = reader.finish() {} else { Issue.record("Oversized EOF frame was not rejected") }
}

@Test func nativeAccountSnapshotRejectsUnknownAuthorityAndMalformedQuarantinedState() throws {
    let initial = try AccountSnapshot.initial(hostId: "synthetic-host")
    for (key, value) in [("route", AccountJSON.string("/tokens")), ("callbackPath", .string("/foreign")), ("revision", .number(1.5)), ("hostId", .string("host\n"))] {
        var object = initial.object; object[key] = value
        #expect(throws: AccountError.invalid) { try AccountSnapshot(value: .object(object)) }
    }
    var invalid = signedOut().object!; invalid["credentials"] = .object(["accessToken": .string("sensitive")])
    #expect(throws: AccountError.invalid) { try AccountSnapshot(value: next(initial, changes: ["accounts": .array([.object(invalid)])])) }
    #expect(throws: AccountError.invalid) { try AccountSnapshot(value: next(initial, changes: ["accounts": .array([signedOut(), signedOut()])])) }
    #expect(throws: AccountError.invalid) { try AccountSnapshot(data: Data(repeating: 32, count: AccountSnapshot.maximumBytes + 1)) }
    #expect(throws: AccountError.invalid) { try AccountJSON.decode(Data(#"{"a":1,"\u0061":2}"#.utf8), limit: 4096) }
}
