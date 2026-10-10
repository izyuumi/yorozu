import Foundation
import CryptoKit
import Security

// Only Yorozu-generated identity and Yorozu-issued token; no OpenClaw credential files.
struct NativeDeviceRecord: Codable, Sendable {
    var privateKey: Data
    var token: String?
    var scopes = ["operator.read", "operator.write"]
}
struct NativeDeviceVault: Sendable {
    let account: String
    private var query: [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"to.yumi.yorozu.gateway",kSecAttrAccount as String:account] }
    func load() throws -> NativeDeviceRecord? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ProjectError.blocked(String(localized: "Yorozu Keychain access failed. Unlock the login Keychain and retry.")) }
        return try JSONDecoder().decode(NativeDeviceRecord.self,from:data)
    }
    func save(_ record: NativeDeviceRecord) throws {
        let data = try JSONEncoder().encode(record)
        var status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary,nil)
        }
        guard status == errSecSuccess else { throw ProjectError.blocked(String(localized: "Could not save Yorozu device enrollment in Keychain. Connection stopped; do not copy credentials into project files.")) }
    }
}
public enum NativeGatewayProtocol {
    public static let clientID = "webchat" // Registered generic client; not reserved internal backend.
    public static let scopes = ["operator.read","operator.write"]
    public static func target(_ value: String) throws -> URL {
        guard let p = URLComponents(string:value), ["ws","wss"].contains(p.scheme ?? ""), ["127.0.0.1","localhost","::1"].contains(p.host ?? ""), p.user == nil, p.password == nil, p.query == nil, p.fragment == nil, ["","/"].contains(p.path), let url = p.url else { throw ProjectError.blocked(String(localized: "Only credential-free loopback Gateway URLs are allowed.")) }
        return url
    }
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    static func proof(key: Curve25519.Signing.PrivateKey,token: String?,scopes: [String],nonce: String,timestamp: Int64) throws -> [String:Any] {
        guard !nonce.isEmpty, nonce.count <= 1024, timestamp >= 0 else { throw ProjectError.invalid(String(localized: "Invalid Gateway challenge; no proof signed.")) }
        let pub = key.publicKey.rawRepresentation; let id = SHA256.hash(data:pub).map { String(format:"%02x",$0) }.joined()
        let payload = ["v3",id,clientID,"ui","operator",scopes.joined(separator:","),String(timestamp),token ?? "",nonce,"macos","mac"].joined(separator:"|")
        return ["id":id,"publicKey":base64URL(pub),"signature":base64URL(try key.signature(for:Data(payload.utf8))),"signedAt":timestamp,"nonce":nonce]
    }
    static func refusal(_ object: [String:Any]) -> ProjectError {
        let error = object["error"] as? [String:Any] ?? [:]; let details = error["details"] as? [String:Any] ?? [:]
        let code = details["code"] as? String ?? error["code"] as? String ?? ""
        if code == "PAIRING_REQUIRED" {
            let raw = details["requestId"] as? String ?? ""
            let id = raw.range(of:"^[a-zA-Z0-9-]{1,100}$",options:.regularExpression) != nil ? raw : "(review pending Yorozu device)"
            return .blocked("Yorozu device pairing pending. Review openclaw devices list on the Gateway host, then approve this exact Yorozu request: \(id). Retry Connect after approval. Do not put credentials in chat.")
        }
        if code == "AUTH_SCOPE_MISMATCH" { return .blocked("Yorozu device recognized, but approved scope grant does not cover this connection. Review pairing; no automatic scope expansion.") }
        if code.hasPrefix("AUTH_") { return .blocked("Yorozu native device authentication was not accepted. Existing model authentication is not disproven. Enroll this separate app privately, or use the configured-credential transport.") }
        // An attachment OpenClaw would not take (`chat-attachments.ts`): named, so the harness can resend without it.
        if (error["message"] as? String ?? "").hasPrefix("UnsupportedAttachmentError") { return .invalid("Gateway refused an attachment (UnsupportedAttachmentError).") }
        return .uncertain("Gateway rejected the request. No automatic replay or workaround; reconcile any active run before retry.")
    }
}

/// Tool row text: "<server>: <tool>[ in <app>]", never arguments. `tool_call` (Tool Search) is named by its target, whose
/// `id` is a catalog id `<source>:<server>:<name>` or a bare name; MCP names are `<server>__<tool>`. A server drops its
/// `yorozu-` prefix and `-driver` suffix ("yorozu-cua-driver" → "cua"). The app comes only from a `pid` (or `target.pid`).
func toolRow(_ name: String,args: Any?) -> String {
    var name = name, args = args as? [String:Any] ?? [:]
    if name == "tool_call", let id = (args["id"] ?? args["toolId"] ?? args["name"]) as? String { name = id; args = args["args"] as? [String:Any] ?? args["input"] as? [String:Any] ?? args }
    var server: Substring?; var tool = Substring(name)
    let parts = name.split(separator:":",maxSplits:2)
    if parts.count == 3 { tool = parts[2]; if parts[0] == "mcp" { server = parts[1]; if tool.hasPrefix(parts[1] + "__") { tool = tool.dropFirst(parts[1].count + 2) } } }
    else if let cut = name.range(of:"__") { server = name[..<cut.lowerBound]; tool = name[cut.upperBound...] }
    if let s = server { var short = s.hasPrefix("yorozu-") ? s.dropFirst(7) : s; if short.hasSuffix("-driver") { short = short.dropLast(7) }; server = short.isEmpty ? s : short }
    let pid = (args["pid"] ?? (args["target"] as? [String:Any])?["pid"]) as? Int
    // The process's outermost .app bundle and its localized display name (AppKit's operators would slow this module's type checks).
    var app: String?; var buffer = [CChar](repeating:0,count:4 * Int(MAXPATHLEN))
    if let pid, pid > 0, pid <= Int(Int32.max), proc_pidpath(Int32(pid),&buffer,UInt32(buffer.count)) > 0 {
        let path = String(cString:buffer)
        if let end = path.range(of:".app/") {
            let bundle = String(path[..<end.lowerBound]) + ".app", info = Bundle(path:bundle)
            app = (info?.object(forInfoDictionaryKey:"CFBundleDisplayName") ?? info?.object(forInfoDictionaryKey:"CFBundleName")) as? String ?? String(path[..<end.lowerBound].split(separator:"/").last ?? "")
        }
    }
    return String(((server.map { $0 + ": " } ?? "") + tool + (app.map { " in " + $0.prefix(60) } ?? "")).prefix(200))
}

/// Multiplexed protocol-4 socket. Every connect/call enforces inherited caller attribution before Keychain/network.
/// Disconnects fail pending calls as uncertain; no automatic mutation replay or remote cancellation claim. After a drop
/// or failed connect it redials in the background (1 s doubling to 60 s) until connected, refused (`blocked`) or `close()`d.
public actor NativeGatewayClient {
    private let url: URL; private let vault: NativeDeviceVault
    private var socket: URLSessionWebSocketTask?; private var session: URLSession?
    private var reader: Task<Void,Never>?; private var connecting: Task<Void,Error>?
    private var ready = false; private var methods = Set<String>(); private var maxPayload = 2_000_000
    private var pending: [String:(Bool,CheckedContinuation<String,Error>)] = [:]
    private var timers: [String:Task<Void,Never>] = [:]
    private var listeners: [UUID:@Sendable (String) async -> Void] = [:]
    private var sequence: Int?
    private var stopped = false; private var retry: Task<Void,Never>?; private var failures = 0
    public init(target: String = "ws://127.0.0.1:18789") throws {
        url = try NativeGatewayProtocol.target(target); vault = NativeDeviceVault(account:url.absoluteString + "|webchat|operator")
    }
    /// A Yorozu device token is stored for this target (Keychain read; no network).
    public nonisolated var isEnrolled: Bool { ((try? vault.load()) ?? nil)?.token?.isEmpty == false }
    // Bootstrap is supplied directly by owner SecureField, never persisted or read from existing credentials.
    // `timeout` bounds the handshake (a launch check passes a short one); calls reconnect with the default.
    public func connect(bootstrapSecret: String? = nil,timeout: Duration = .seconds(15)) async throws {
        try GatewayRPC.enforceAttribution(ProcessInfo.processInfo.environment)
        stopped = false
        if ready { return }; if let connecting { return try await connecting.value }
        let task = Task { try await self.handshake(bootstrapSecret:bootstrapSecret,timeout:timeout) }; connecting = task
        do { try await task.value; connecting = nil; failures = 0 } catch {
            connecting = nil; teardown()
            if case ProjectError.blocked = error {} else { redial() }
            throw error
        }
    }
    private func redial() {
        guard !stopped, retry == nil else { return }
        let delay = min(60,1 << min(failures,6)); failures += 1
        retry = Task { try? await Task.sleep(for:.seconds(delay)); if !Task.isCancelled { await self.redialed() } }
    }
    private func redialed() async { retry = nil; if !stopped { try? await connect() } }
    private func handshake(bootstrapSecret: String?,timeout: Duration) async throws {
        var record = try vault.load() ?? NativeDeviceRecord(privateKey:Curve25519.Signing.PrivateKey().rawRepresentation)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:record.privateKey)
        try vault.save(record) // Same identity across pending-pairing attempts.
        let bootstrap = bootstrapSecret.flatMap { $0.isEmpty ? nil : $0 }
        guard let token = bootstrap ?? record.token, !token.isEmpty else { throw ProjectError.blocked(String(localized: "Separate Yorozu native device not enrolled. Enter the Gateway bootstrap secret privately in Connect, or use the already-authenticated configured transport. No existing credentials were extracted.")) }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 120; config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration:config); self.session = session
        let ws = session.webSocketTask(with:url); ws.maximumMessageSize = maxPayload; socket = ws; ws.resume()
        let deadline = Task { try? await Task.sleep(for:timeout); if !Task.isCancelled { ws.cancel(with:.goingAway,reason:nil) } }; defer { deadline.cancel() }
        let challenge = try await receive(ws)
        guard challenge["type"] as? String == "event", challenge["event"] as? String == "connect.challenge", let payload = challenge["payload"] as? [String:Any], let nonce = payload["nonce"] as? String, let number = payload["ts"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue, number.doubleValue < Double(Int64.max) else { throw ProjectError.invalid(String(localized: "Gateway did not supply a valid protocol-4 challenge.")) }
        let id = identifier()
        let params: [String:Any] = ["minProtocol":4,"maxProtocol":4,"client":["id":NativeGatewayProtocol.clientID,"displayName":"Yorozu","version":"R1","platform":"macos","deviceFamily":"mac","mode":"ui"],"role":"operator","scopes":record.scopes,"caps":["tool-events"],"auth":["token":token],"device":try NativeGatewayProtocol.proof(key:key,token:token,scopes:record.scopes,nonce:nonce,timestamp:number.int64Value)]
        try await send(["type":"req","id":id,"method":"connect","params":params],on:ws)
        let response = try await receive(ws)
        guard response["type"] as? String == "res", response["id"] as? String == id else { throw ProjectError.invalid(String(localized: "Unexpected Gateway handshake frame.")) }
        guard response["ok"] as? Bool == true else { throw NativeGatewayProtocol.refusal(response) }
        guard let hello = response["payload"] as? [String:Any], hello["type"] as? String == "hello-ok", hello["protocol"] as? Int == 4, let auth = hello["auth"] as? [String:Any], auth["role"] as? String == "operator", let scopes = auth["scopes"] as? [String], Set(NativeGatewayProtocol.scopes).isSubset(of:Set(scopes)), let features = hello["features"] as? [String:Any], let advertised = features["methods"] as? [String], let policy = hello["policy"] as? [String:Any], let limit = policy["maxPayload"] as? Int, limit > 0 else { throw ProjectError.blocked(String(localized: "Gateway handshake lacks required protocol, read/write grant or method/size contract.")) }
        if let issued = auth["deviceToken"] as? String, !issued.isEmpty, record.token != issued { record.token = issued; record.scopes = scopes; try vault.save(record) }
        guard record.token != nil else { throw ProjectError.blocked(String(localized: "Gateway did not issue a reusable Yorozu device token. Review pairing; bootstrap secret was not saved.")) }
        maxPayload = min(limit,8_000_000); methods = Set(advertised); ready = true; sequence = nil
        reader = Task { await self.readLoop(ws) }
    }
    /// `deadline`: seconds before the call fails as uncertain (default 270; a long thinking step passes its own).
    public func call(_ method: String,json: String,final: Bool,deadline: Int = 270) async throws -> String {
        try GatewayRPC.enforceAttribution(ProcessInfo.processInfo.environment); try await connect()
        guard ready, let ws = socket, methods.contains(method) else { throw ProjectError.blocked(String(localized: "Gateway does not advertise requested method; no alternate dispatch attempted.")) }
        let params = try JSONSerialization.jsonObject(with:Data(json.utf8)); let id = identifier()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = (final,continuation)
                timers[id] = Task { try? await Task.sleep(for:.seconds(deadline)); if !Task.isCancelled { self.fail(id,ProjectError.uncertain(String(localized: "Gateway deadline elapsed; remote run may still be active. Reconcile before retry."))) } }
                Task { do { try await self.send(["type":"req","id":id,"method":method,"params":params],on:ws) } catch { self.fail(id,ProjectError.uncertain(String(localized: "Gateway send failed; delivery uncertain. No automatic replay."))) } }
            }
        },onCancel:{ Task { await self.cancelPending(id) } })
    }
    private func cancelPending(_ id: String) { fail(id,ProjectError.uncertain(String(localized: "Local observation cancelled; remote execution is not confirmed stopped."))) }
    private func fail(_ id: String,_ error: Error) { timers.removeValue(forKey:id)?.cancel(); pending.removeValue(forKey:id)?.1.resume(throwing:error) }
    /// Disconnects and stops redialing until the next `connect`.
    public func close() { stopped = true; retry?.cancel(); retry = nil; teardown() }
    private func teardown() {
        ready = false; reader?.cancel(); reader = nil; socket?.cancel(with:.goingAway,reason:nil); socket = nil; session?.invalidateAndCancel(); session = nil
        for id in Array(pending.keys) { fail(id,ProjectError.uncertain(String(localized: "Gateway disconnected. Saved work retained; reconcile before retry."))) }; sequence = nil
    }
    // In-memory only. Consumers filter owned run/session and public channels before persistence.
    public func observe(_ handler: @escaping @Sendable (String) async -> Void) -> UUID { let id = UUID(); listeners[id] = handler; return id }
    public func removeObserver(_ id: UUID) { listeners[id] = nil }
    private func readLoop(_ ws: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let frame = try await receive(ws)
                if frame["type"] as? String == "res", let id = frame["id"] as? String, let request = pending[id] {
                    guard frame["ok"] as? Bool == true else { fail(id,NativeGatewayProtocol.refusal(frame)); continue }
                    let payload = frame["payload"] as? [String:Any] ?? [:]
                    if request.0 && payload["status"] as? String == "accepted" { continue }
                    let value = String(decoding:try JSONSerialization.data(withJSONObject:payload),as:UTF8.self)
                    timers.removeValue(forKey:id)?.cancel(); pending.removeValue(forKey:id)?.1.resume(returning:value)
                } else if frame["type"] as? String == "event" {
                    if let seq = frame["seq"] as? Int {
                        if let prior = sequence, seq <= prior { continue }
                        if let prior = sequence, seq > prior + 1 { throw ProjectError.uncertain(String(localized: "Gateway event gap; reconnect and reconcile exact owned runs before retry.")) }; sequence = seq
                    }
                    guard ["agent","chat"].contains(frame["event"] as? String ?? "") else { continue }
                    let value = String(decoding:try JSONSerialization.data(withJSONObject:frame),as:UTF8.self)
                    for handler in listeners.values { await handler(value) }
                }
            }
        } catch { if socket === ws { teardown(); redial() } }
    }
    private func receive(_ ws: URLSessionWebSocketTask) async throws -> [String:Any] {
        let message = try await ws.receive(); let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw ProjectError.invalid(String(localized: "Unsupported Gateway frame.")) }
        guard data.count <= maxPayload, let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw ProjectError.invalid(String(localized: "Invalid/oversized Gateway frame.")) }; return object
    }
    private func send(_ object: [String:Any],on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject:object); guard data.count <= maxPayload else { throw ProjectError.invalid(String(localized: "Gateway request exceeds negotiated frame size.")) }
        try await ws.send(.string(String(decoding:data,as:UTF8.self)))
    }
}
