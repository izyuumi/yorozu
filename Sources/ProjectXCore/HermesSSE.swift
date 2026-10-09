import Foundation
import Security

/// One Hermes run as `GET /v1/runs/{id}` (or its terminal event) reports it (Hermes 0.21.6,
/// gateway/platforms/api_server_runs.py). `provider`/`model` are `runtime`: the pair that actually served the run;
/// `requested*` is `runtime.requested`, what the request named.
struct HermesRun: Sendable {
    var id: String, status: String, output: String?, error: String?, sessionID: String?, pendingSteer: String?
    var provider: String?, model: String?, requestedProvider: String?, requestedModel: String?
    var terminal: Bool { ["completed", "failed", "cancelled", "interrupted"].contains(status) }
    init(_ j: [String:Any]) {
        id = j["run_id"] as? String ?? ""; status = j["status"] as? String ?? (j["event"] as? String).map { String($0.dropFirst(4)) } ?? ""
        output = j["output"] as? String; error = j["error"] as? String; sessionID = j["session_id"] as? String
        // A string in 0.21.6; joined defensively should it become a list.
        pendingSteer = j["pending_steer"] as? String ?? (j["pending_steer"] as? [String])?.joined(separator: "\n")
        let r = j["runtime"] as? [String:Any], q = r?["requested"] as? [String:Any]
        provider = r?["provider"] as? String; model = r?["model"] as? String
        requestedProvider = q?["provider"] as? String; requestedModel = q?["model"] as? String
    }
}

/// Loopback HTTP client for the Hermes API server. Each profile is served at `<root>/p/<profile>/…` (multiplexing) and
/// takes only its own bearer key, read from the Keychain per request. The key never goes into a URL, log or error text.
struct HermesClient: Sendable {
    /// Transport failure: nothing is known about whether the request was admitted.
    struct Unreachable: LocalizedError { var errorDescription: String? }
    static let keychainService = "to.yumi.yorozu.hermes"
    static let terminalEvents: Set<String> = ["run.completed", "run.failed", "run.cancelled", "run.interrupted"]
    /// Ephemeral: no cookies, cache or credential store. 60 s idle timeout; SSE streams send `: keepalive` every 10 s.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 60; c.httpCookieStorage = nil; c.urlCache = nil; c.urlCredentialStorage = nil
        return URLSession(configuration: c)
    }()
    let root: String

    /// Only credential-free loopback http(s) URLs with no path, query or fragment.
    init(_ url: String) throws {
        guard Config.isLoopbackHTTP(url), let u = URL(string: url) else { throw ProjectError.blocked("Only loopback Hermes URLs with no path are allowed, such as http://127.0.0.1:8642.") }
        root = u.absoluteString.hasSuffix("/") ? String(u.absoluteString.dropLast()) : u.absoluteString
    }
    /// An empty profile is the default profile's own listener at the root.
    func url(_ profile: String, _ path: String) -> URL { URL(string: root + (profile.isEmpty ? "" : "/p/" + profile) + path)! }

    /// The profile's `API_SERVER_KEY`, mirrored by setup into Keychain item `to.yumi.yorozu.hermes` / account = profile.
    static func key(_ profile: String) throws -> String {
        let q: [String:Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: profile,
                               kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw HarnessError.notReady("No Hermes API key for profile \(profile) in the Keychain. Run the Hermes setup step.") }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { throw ProjectError.blocked("Yorozu could not read the Hermes API key from the Keychain. Unlock the login Keychain and retry.") }
        return key
    }

    func request(_ profile: String, _ method: String, _ path: String, body: [String:Any]? = nil, headers: [String:String] = [:], auth: Bool = true, timeout: TimeInterval = 30) throws -> URLRequest {
        var r = URLRequest(url: url(profile, path), timeoutInterval: timeout); r.httpMethod = method
        if auth { r.setValue("Bearer " + (try Self.key(profile)), forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
    /// One JSON call: the HTTP status and the decoded object (empty when the body is not a JSON object).
    func call(_ profile: String, _ method: String, _ path: String, body: [String:Any]? = nil, headers: [String:String] = [:], auth: Bool = true) async throws -> (status: Int, json: [String:Any]) {
        let r = try request(profile, method, path, body: body, headers: headers, auth: auth)
        let data: Data, response: URLResponse
        do { (data, response) = try await Self.session.data(for: r) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Unreachable(errorDescription: "Hermes is unreachable at \(root) (\((error as? URLError)?.code.rawValue ?? -1)). Is `hermes gateway` running?") }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] ?? [:])
    }
    static func errorCode(_ json: [String:Any]) -> String? { (json["error"] as? [String:Any])?["code"] as? String }
    /// A refusal as a plain error: 401/403 and 429 get their own wording; the server's message only when not secret-shaped.
    static func failure(_ status: Int, _ json: [String:Any], profile: String, doing: String) -> Error {
        if status == 401 || status == 403 { return HarnessError.notReady("Hermes refused Yorozu's API key for profile \(profile) (HTTP \(status)). Run the Hermes setup step again.") }
        if status == 429 { return HarnessError.busy("Hermes is busy: it already runs its maximum number of runs at once. Nothing was started; try again shortly.") }
        let e = json["error"] as? [String:Any], message = e?["message"] as? String ?? ""
        let detail = (errorCode(json).map { " " + $0 } ?? "") + (message.isEmpty || sensitive(message) ? "" : ": " + utf8Prefix(message, bytes: 300))
        return ProjectError.uncertain("Hermes could not \(doing) (HTTP \(status)\(detail)).")
    }

    /// `GET /v1/runs/{id}`; nil on 404 (unknown to this profile, or forgotten: terminal statuses are kept 1 h, 24 h durably).
    func status(_ profile: String, _ run: String) async throws -> HermesRun? {
        let (code, json) = try await call(profile, "GET", "/v1/runs/" + run)
        if code == 404 { return nil }
        guard code == 200 else { throw Self.failure(code, json, profile: profile, doing: "report run \(run)") }
        return HermesRun(json)
    }

    /// Streams `GET /v1/runs/{id}/events` to `onEvent` until a terminal event, resuming with `Last-Event-ID` after a drop,
    /// then returns the run's terminal status. Frames are `id: <seq>` + `data: <json>` (the event name is the payload's
    /// `event`, its sequence `seq`); `:` lines (`: open`, `: keepalive`, `: stream closed`) are skipped. Once the server has
    /// dropped the buffer (404, 300 s after the last subscriber left) or the stream keeps failing, it polls the status.
    /// A key refused (401/403) after the run started stops the run first; if even the stop is refused, the run may go on
    /// unwatched, so the work ends uncertain rather than failed.
    func follow(_ profile: String, run: String, onEvent: ([String:Any]) async throws -> Void) async throws -> HermesRun {
        do { return try await stream(profile, run: run, onEvent: onEvent) } catch HarnessError.notReady(let text) {
            if (try? await call(profile, "POST", "/v1/runs/\(run)/stop"))?.status == 200 { throw HarnessError.notReady(text) }
            throw ProjectError.uncertain(text + " Run \(run) may still be going; reconcile before retry.")
        }
    }
    private func stream(_ profile: String, run: String, onEvent: ([String:Any]) async throws -> Void) async throws -> HermesRun {
        var last: Int?, failures = 0
        streaming: while failures < 10 {
            try Task.checkCancellation()
            do {
                // No overall timeout: a long tool call keeps the stream open; the 60 s idle limit still applies.
                var r = try request(profile, "GET", "/v1/runs/\(run)/events", headers: ["Accept": "text/event-stream"], timeout: 60)
                if let last { r.setValue(String(last), forHTTPHeaderField: "Last-Event-ID") }
                let (bytes, response) = try await Self.session.bytes(for: r)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { break streaming }
                guard code == 200 else { throw Self.failure(code, [:], profile: profile, doing: "stream run \(run)") }
                failures = 0
                // Dispatch on each `data:` line: Hermes writes one per frame, so blank separators are not needed.
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:"), let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String:Any] else { continue }
                    if let seq = event["seq"] as? Int { last = seq }
                    try await onEvent(event)
                    if Self.terminalEvents.contains(event["event"] as? String ?? "") { break streaming }
                }
                // Closed without a terminal frame (slow-subscriber cut, or the run ended before we attached): check.
                if let s = try await status(profile, run), s.terminal { return s }
            } catch let e as ProjectError { throw e } catch let e as HarnessError { throw e } catch is CancellationError { throw CancellationError() } catch {
                failures += 1; try await Task.sleep(for: .seconds(min(failures * 2, 15)))
            }
        }
        var misses = 0
        while true {
            try Task.checkCancellation()
            do {
                guard let s = try await status(profile, run) else { throw ProjectError.uncertain("Hermes no longer knows run \(run); it may have finished. Reconcile before retry.") }
                if s.terminal { return s }; misses = 0
            } catch is Unreachable {
                misses += 1
                if misses >= 120 { throw ProjectError.uncertain("Hermes was unreachable for about 10 min while run \(run) was going; it may still be active.") }
            }
            try await Task.sleep(for: .seconds(5))
        }
    }
}
