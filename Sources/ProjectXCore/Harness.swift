import Foundation
import CryptoKit

/// A coding executor a harness offers (#318 H4). `id` is stored in `work.executor`; an empty list means no coding.
public struct Executor: Codable, Sendable, Equatable {
    public var id: String, name: String
    /// Gets Yorozu's MCP servers, so it can operate apps and browsers.
    public var appAccess: Bool
    /// Takes changes while a run is going; otherwise they wait for a follow-up turn.
    public var liveSteer: Bool
    /// Harness-specific routing guidance for the secretary policy.
    public var routingNotes: String
    /// Nil when ready; otherwise why not.
    public var notReady: String?
    /// The model runtime it runs on, matched against `ModelInfo.runtimes` for its automatic model; nil means none.
    public var runtime: String?
    public init(id: String, name: String, appAccess: Bool, liveSteer: Bool, runtime: String? = nil, routingNotes: String = "", notReady: String? = nil) { self.id = id; self.name = name; self.appAccess = appAccess; self.liveSteer = liveSteer; self.runtime = runtime; self.routingNotes = routingNotes; self.notReady = notReady }
}

public protocol Harness: Sendable {
    var name: String { get }
    /// Stable harness id: openclaw, hermes, fixture, offline.
    var id: String { get }
    /// Coding executors this harness offers, in preference order.
    var executors: [Executor] { get }
    var agentID: String { get }
    func route(_ input: RoutingInput, stronger: Bool) async throws -> Decision
    func run(_ input: WorkerInput, update: @escaping @Sendable (StreamUpdate) async throws -> Void, memory: @escaping @Sendable (MemoryCall) async throws -> String) async throws -> WorkerOutput
    func steer(_ work: Work, topic: Topic, amendment: Amendment) async throws -> Bool
    func cancel(_ work: Work, topic: Topic) async throws -> Bool
    func reconcile(_ work: Work, topic: Topic) async throws -> RunStatus
    func extract(_ message: Message, existing: [MemoryHit]) async throws -> [MemoryProposal]
    /// The models the harness's agent may use, and its primary model, for the smart role defaults (#312).
    func models() async throws -> (allowed: [ModelInfo], primary: String?)
    /// UTF-8 byte cap on a role run's final prompt (secretary, review, extraction); the Engine's routing trim measures against it.
    var rawPromptCap: Int { get }
    /// UTF-8 byte cap on one worker step's message, checked before the run handle is stamped.
    var workerGuard: Int { get }
}
public extension Harness {
    var agentID: String { "projectx" }
    var executors: [Executor] { [] }
    var rawPromptCap: Int { ProjectXCore.rawPromptCap }
    var workerGuard: Int { 32000 }
    func extract(_ message: Message, existing: [MemoryHit]) async throws -> [MemoryProposal] { [] }
    func models() async throws -> (allowed: [ModelInfo], primary: String?) { ([],nil) }
}
/// Settings the app can change while it runs (#312). The harness and the Engine read them through a closure at the start
/// of each route, task or extraction, so a change applies from the next one without rebuilding either.
public struct HarnessSettings: Sendable {
    /// Role models as "<provider>/<model>"; `codingModels` is keyed by the harness's executor id. Empty means none set.
    public var secretaryModel = "", extractionModel = "", workerModel = "", reviewModel = "", codingModels: [String:String] = [:]
    /// Yorozu's MCP servers; nil leaves OpenClaw's own MCP setup untouched.
    public var mcpServers: [String:MCPServer]?
    /// Lifts the ask-first rules for requested outward-facing steps and the risky cua tools (owner, 2026-10-09).
    public var yolo = false
    /// The dev checkout coding workers merge into; nil refuses coding work.
    public var devRepo: URL?
    /// `devRepo`'s branch coding worktrees are cut from and merged into, and the command (relative to the main checkout)
    /// that rebuilds and restarts the app; the coding contract names both.
    public var codingBaseBranch = "projectx", buildCommand = "scripts/build_native.sh --restart"
    /// `config.toml`, named in the thinking contract so a worker can change settings when asked.
    public var configFile: URL?
    /// Routing hints: the user's knowledge source the secretary cannot read ("" drops it), and the topic for this app.
    public var personalKnowledge = "", selfTopic = "Yorozu"
    public init() {}
}
public struct OfflineHarness: Harness {
    public let id = "offline"
    public let name = "Offline · no model calls"
    public init() {}
    public func route(_ input: RoutingInput, stronger: Bool) async throws -> Decision { throw ProjectError.offline }
    public func run(_ input: WorkerInput, update: @escaping @Sendable (StreamUpdate) async throws -> Void, memory: @escaping @Sendable (MemoryCall) async throws -> String) async throws -> WorkerOutput { throw ProjectError.offline }
    public func steer(_ work: Work, topic: Topic, amendment: Amendment) async throws -> Bool { false }
    public func cancel(_ work: Work, topic: Topic) async throws -> Bool { false }
    public func reconcile(_ work: Work, topic: Topic) async throws -> RunStatus { .unknown }
}

/// Opt-in synthetic fixture; no model, Gateway, accounts, private data or external tools.
public actor FixtureHarness: Harness {
    nonisolated public let id = "fixture"
    nonisolated public let name = "Synthetic fixture · NOT a live model"
    private var states: [String: RunStatus] = [:]; private var revisions: [String: Int] = [:]; private var cancelled = Set<String>()
    public init() {}
    public func route(_ input: RoutingInput, stronger: Bool) async throws -> Decision {
        let text = input.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = input.latestTopic ?? input.topics.last?.id
        if text.lowercased() == "retry" { return Decision(action: "retry",topicID: latest,taskID: input.work.last(where: { ["failed","uncertain"].contains($0.state) })?.id,instruction: "Continue the failed request") }
        if text.lowercased().hasPrefix("new topic:") { return Decision(action: "delegate",newTopic: String(text.dropFirst(10)).trimmingCharacters(in: .whitespaces),instruction: text) }
        if text.lowercased().hasPrefix("i meant "), let target = input.topics.first(where: { text.lowercased().contains($0.label.lowercased()) }), let prior = input.work.last(where: { $0.topicID != target.id }) {
            return Decision(action: "correct",topicID: target.id,taskID: prior.id,instruction: "Apply this correction to the original request: \(text)")
        }
        if text.lowercased() == "hello" { return Decision(action: "reply",topicID: latest,reply: "Synthetic fixture: the main conversation remains available.") }
        if let active = input.work.last(where: { $0.topicID == latest && ["queued","working","amendment_pending","cancellation_requested"].contains($0.state) }) { return Decision(action: "steer",topicID: latest,taskID: active.id,instruction: text) }

        return Decision(action: "delegate",topicID: latest,newTopic: latest == nil ? "Sample topic" : nil,instruction: text)
    }
    public func run(_ input: WorkerInput, update: @escaping @Sendable (StreamUpdate) async throws -> Void, memory: @escaping @Sendable (MemoryCall) async throws -> String) async throws -> WorkerOutput {
        let id = input.work.id; states[id] = .running
        try await update(.handle(RunHandle(sessionKey: input.topic.sessionKey,controllerKey: "fixture-controller",runID: "fixture-" + id)))
        try await update(.event(WorkerEvent(id: id + "-start",taskID: id,kind: "fixture_progress",body: "Synthetic fixture is processing this request (not model reasoning).",created: Date().timeIntervalSince1970)))
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(100)); if cancelled.contains(id) { states[id] = .stopped; throw ProjectError.invalid("Synthetic cancellation acknowledged.") } }
        if input.instructionText.lowercased().contains("simulate failure") && !input.instructionText.contains("User requested retry:") { states[id] = .stopped; throw ProjectError.invalid("Synthetic worker failure; ask to retry.") }
        let answer = WorkerOutput(text: "Synthetic fixture result for: \(input.work.instruction)\n\nThis verifies local workflow, not model quality or live integration.",appliedRevision: revisions[id] ?? input.work.revision)
        states[id] = .completed(answer); return answer
    }
    public func steer(_ work: Work, topic: Topic, amendment: Amendment) async throws -> Bool { revisions[work.id] = amendment.revision; return true }
    public func cancel(_ work: Work, topic: Topic) async throws -> Bool { cancelled.insert(work.id); states[work.id] = .stopped; return true }
    public func reconcile(_ work: Work, topic: Topic) async throws -> RunStatus { states[work.id] ?? .unknown }
}
private extension WorkerInput { var instructionText: String { work.instruction } }

public typealias RPCCall = @Sendable (_ method: String, _ json: String, _ final: Bool) async throws -> String
public struct GatewayRPC: Sendable {
    private let fixture: RPCCall?
    public let native: NativeGatewayClient?
    private let audit: RequestAudit?
    /// The CLI transport's Gateway; only plain loopback `ws`/`wss` URLs are used.
    private let target: String
    public init(fixture: RPCCall? = nil, native: NativeGatewayClient? = nil, audit: RequestAudit? = nil, target: String = "ws://127.0.0.1:18789") { self.fixture = fixture; self.native = native; self.audit = audit; self.target = target }
    public static func enforceAttribution(_ environment: [String:String]) throws {
        if environment["OPENCLAW_SHELL"] == "exec" || environment["OPENCLAW_SUBAGENT_EXEC"] != nil {
            throw ProjectError.blocked("Gateway agent-exec caller-attribution prohibition: no Gateway subprocess launched. No marker removal, native-launch workaround or new authentication is permitted/required.")
        }
    }
    public static func diagnosticCategory(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("provider/model overrides are not authorized") { return "model-override-not-authorized" }
        if s.contains("agent exec") || s.contains("inter-session attribution") { return "caller-attribution-restriction" }
        if s.contains("missing scope") || s.contains("forbidden") { return "scope-denied" }
        if s.contains("pairing required") || s.contains("pairing_required") { return "device-pairing-required" }
        if s.contains("unauthorized") || s.contains("auth_token") || s.contains("token mismatch") { return "authentication-refused" }
        if s.contains("unknown option") || s.contains("invalid agent params") || s.contains("invalid request") || s.contains("invalid_request") { return "request-schema" }
        if s.contains("econnrefused") || s.contains("connection refused") { return "gateway-unreachable" }
        if s.contains("expect-url") || s.contains("gateway url mismatch") || s.contains("destination changed") { return "gateway-target-mismatch" }
        if s.contains("timed out") || s.contains("timeout") { return "deadline-or-timeout" }
        if s.contains("no such file") || s.contains("command not found") || s.contains("node.js") { return "executable-or-runtime" }
        return "unclassified-refusal-or-disconnect"
    }
    public func call(_ method: String, _ params: [String:Any], final: Bool = false, sourceMessageID: String? = nil) async throws -> [String:Any] {
        guard method == "agent", let id = params["idempotencyKey"] as? String else { return try await perform(method,params,final: final) }
        // Correlation log only. Raw model runs are stateless (no tools, no transcript), so a lost one never blocks the next.
        var receipt = RequestReceipt(requestID: id,harness: "openclaw",sessionKey: params["sessionKey"] as? String,sourceMessageID: sourceMessageID,rawModelRun: params["modelRun"] as? Bool == true,state: "submitted")
        try await audit?(receipt) // Durable before dispatch; fail closed if saving correlation fails.
        do {
            let result = try await perform(method,params,final: final)
            let status = result["status"] as? String ?? ""
            receipt.state = ["ok","error","timeout"].contains(status) ? "terminal" : status == "accepted" ? "admitted" : "uncertain"
            receipt.created = Date().timeIntervalSince1970; try await audit?(receipt); return result
        } catch {
            if case ProjectError.blocked = error { receipt.state = "not-sent" }
            else if error.localizedDescription.contains("category=model-override-not-authorized") { receipt.state = "rejected" }
            else { receipt.state = "uncertain" }
            receipt.created = Date().timeIntervalSince1970; try? await audit?(receipt)
            throw ProjectError.uncertain(error.localizedDescription + " Request ID: " + id)
        }
    }
    private func perform(_ method: String, _ params: [String:Any], final: Bool) async throws -> [String:Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: params),as: UTF8.self)
        let text: String
        if let fixture { text = try await fixture(method,json,final) }
        else if let native { text = try await native.call(method,json: json,final: final) }
        else {
            let env = ProcessInfo.processInfo.environment
            try Self.enforceAttribution(env)
            let target = target
            guard let url = URLComponents(string: target), ["ws","wss"].contains(url.scheme ?? ""), ["127.0.0.1","::1","localhost"].contains(url.host ?? ""), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else { throw ProjectError.blocked("Only loopback Gateway targets are allowed.") }
            text = try await Task.detached(priority: .utility) {
                let process = Process(); let pipe = Pipe(); let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["openclaw","gateway","call",method,"--json","--expect-url",target,"--timeout","260000","--params",json] + (final ? ["--expect-final"] : [])
                var childEnvironment = env // Never strip runtime attribution markers.
                // Finder's PATH often omits Homebrew; append standard executable locations, never change identity/auth homes.
                childEnvironment["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
                process.environment = childEnvironment
                process.standardOutput = pipe; process.standardError = errors
                do { try process.run() } catch { throw ProjectError.blocked("Gateway CLI launch failed [category=executable-unavailable]. No request was launched.") }
                // Drain both pipes concurrently; keep a bounded diagnostic buffer in memory only.
                let errorReader = Task.detached { () -> Data in
                    var captured = Data()
                    while let part = try? errors.fileHandleForReading.read(upToCount: 8192), !part.isEmpty {
                        if captured.count < 32768 { captured.append(part.prefix(32768 - captured.count)) }
                    }
                    return captured
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 270,execute: deadline)
                defer { deadline.cancel() }
                var data = Data()
                while true {
                    let part = try pipe.fileHandleForReading.read(upToCount: 65536) ?? Data()
                    if part.isEmpty { break }; data.append(part)
                    // chat.history answers ≤ 512 KiB of messages; chat.message.get one whole message, up to 1,000,000 chars per text field.
                    if data.count > (["chat.history","chat.message.get"].contains(method) ? 16_000_000 : 2_000_000) { process.terminate(); throw ProjectError.uncertain("Gateway response too large; underlying run may remain active.") }
                }
                process.waitUntilExit()
                let stderr = await errorReader.value
                guard process.terminationStatus == 0 else {
                    let category = Self.diagnosticCategory(String(decoding: stderr + data.prefix(32768),as: UTF8.self))
                    // Gateway refusals arrive as a JSON envelope on stdout; its code/message is safe to show unless secret-shaped.
                    let refusal = (try? JSONSerialization.jsonObject(with: data) as? [String:Any])?["error"] as? [String:Any]
                    let detail = (refusal?["message"] as? String).flatMap { sensitive($0) ? nil : ": \(refusal?["code"] as? String ?? "error") \($0.prefix(300))" } ?? ""
                    throw ProjectError.uncertain("Gateway CLI failed [exit=\(process.terminationStatus), category=\(category)]\(detail). No automatic replay; reconcile any admitted run before retry.")
                }
                return String(decoding: data,as: UTF8.self)
            }.value
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any], obj["ok"] as? Bool != false || method == "sessions.compact" else { throw ProjectError.uncertain("Gateway refused or returned an invalid envelope; no automatic replay.") }
        return obj
    }
}

public struct OpenClawHarness: Harness {
    public let id = "openclaw"
    public let name = "Configured OpenClaw · live acceptance unverified"
    public var agentID: String { agent }
    public var agent: String; public var rpc: GatewayRPC; public var workspace: URL
    /// Models, MCP servers, YOLO, dev repo and config path, read at the start of each route, task or extraction.
    public var settings: @Sendable () -> HarnessSettings
    private let sessions = SessionCreations(); private let mcp = MCPMirror()
    /// Claude Code (runtime claude-cli) and Codex (runtime codex), each in an OpenClaw-managed worktree. Neither takes
    /// changes mid-run (unverified), so changes wait for a follow-up turn.
    public var executors: [Executor] { [
        Executor(id: "claude",name: "Claude Code",appAccess: false,liveSteer: false,runtime: "claude-cli"),
        Executor(id: "codex",name: "Codex",appAccess: true,liveSteer: false,runtime: "codex",
                 routingNotes: "New coding work that also needs to operate an app or a browser (e.g. App Store Connect) uses executor \"codex\" unless the user names Claude Code."),
    ] }
    public init(workspace: URL, agent: String = "projectx", rpc: GatewayRPC = GatewayRPC(), settings: @escaping @Sendable () -> HarnessSettings = { HarnessSettings() }) {
        self.workspace = workspace; self.agent = agent; self.rpc = rpc; self.settings = settings
    }
    /// `models.list` (operator.read, view "configured" with details): the agent's allowed models, its primary (tag
    /// "default"), context, inputs and runtime. Price and output cap only from `config.get` (operator.read), in
    /// `models.providers.<provider>.models[]`; models.list strips cost, and bundled provider catalogs are not exposed.
    public func models() async throws -> (allowed: [ModelInfo], primary: String?) {
        let rows = try await rpc.call("models.list",["agentId":agent,"view":"configured","includeDetails":true])["models"] as? [[String:Any]] ?? []
        let providers = (((try? await rpc.call("config.get",[:]))?["config"] as? [String:Any])?["models"] as? [String:Any])?["providers"] as? [String:Any] ?? [:]
        var primary: String?, allowed: [ModelInfo] = []
        for m in rows {
            guard let id = m["id"] as? String, let provider = m["provider"] as? String else { continue }
            if (m["tags"] as? [String] ?? []).contains("default") { primary = provider + "/" + id }
            guard m["available"] as? Bool != false else { continue }
            let p = providers[provider] as? [String:Any], definition = (p?["models"] as? [[String:Any]])?.first { $0["id"] as? String == id }
            let cost = definition?["cost"] as? [String:Any]
            // Runtimes: the model's own, available picker alternatives, and what OpenClaw's session-runtime-compat allows
            // (codex for providers openai and codex; claude-cli through the anthropic plugin's CLI backend).
            let runtimeID = { (r: Any?) in (r as? [String:Any])?["id"] as? String }
            let runtimes = [runtimeID(m["agentRuntime"]) ?? "openclaw"] + (m["runtimeChoices"] as? [[String:Any]] ?? []).filter { $0["available"] as? Bool == true }.compactMap { runtimeID($0["agentRuntime"]) }
                + (["openai","codex"].contains(provider) ? ["codex"] : []) + (["anthropic","claude-cli"].contains(provider) ? ["claude-cli"] : [])
            allowed.append(ModelInfo(id: provider + "/" + id,contextTokens: m["contextTokens"] as? Int ?? m["contextWindow"] as? Int,maxOutputTokens: definition?["maxTokens"] as? Int ?? p?["maxTokens"] as? Int,
                                     price: (cost?["input"] as? Double).flatMap { i in (cost?["output"] as? Double).map { i + $0 } }.flatMap { $0 > 0 ? $0 : nil }, // a 0/0 cost (e.g. a local proxy) is unknown, not free
                                    inputs: m["input"] as? [String] ?? [],runtimes: Array(Set(runtimes)).sorted()))
        }
        return (allowed,primary)
    }
    private func text(_ envelope: [String:Any]) throws -> String {
        let meta = (envelope["result"] as? [String:Any])?["meta"] as? [String:Any] ?? [:]
        // A failed run still carries result.meta.error (status "error"); these two kinds repeat on a plain retry.
        if let kind = (meta["error"] as? [String:Any])?["kind"] as? String, ["context_overflow","compaction_failure"].contains(kind) { throw ProjectError.overflow("The model's context window was exceeded (\(kind)).") }
        guard envelope["status"] as? String == "ok", let result = envelope["result"] as? [String:Any] else { throw ProjectError.uncertain("Gateway did not confirm successful completion.") }
        guard meta["error"] == nil, meta["aborted"] as? Bool != true, result["aborted"] as? Bool != true else { throw ProjectError.invalid("Gateway reported model error/abort.") }
        let payloads = result["payloads"] as? [[String:Any]] ?? []
        guard !payloads.contains(where: { $0["isError"] as? Bool == true }) else { throw ProjectError.invalid("Gateway error payload.") }
        // terminalReply (result.* for session turns, meta.* for raw runs) is a 4096-char preview: it gates visibility only.
        // Suppressed/non-visible output never falls back to a payload; the full text lives in payloads.
        let terminal = (result["terminalReply"] ?? meta["terminalReply"]) as? [String:Any]
        guard terminal.map({ $0["disposition"] as? String == "visible" }) ?? true,
              let value = payloads.last(where: { $0["isReasoning"] as? Bool != true })?["text"] as? String,
              !value.isEmpty else { throw ProjectError.invalid("Gateway output empty or hidden; withheld.") }
        return value
    }
    private func model(_ prompt: String, model: String, sourceMessageID: String? = nil) async throws -> String {
        guard agent == "projectx" else { throw ProjectError.blocked("Live R1 requires the dedicated projectx agent; personal agents are not an app backend.") }
        guard prompt.utf8.count <= rawPromptCap else { throw ProjectError.invalid("Model input exceeds bounded context.") }
        guard !model.isEmpty else { throw ProjectError.blocked("No model is set for this role; choose one in Settings › Advanced.") }
        // Public CLI `agent` connects with operator.write; per-turn model overrides require admin.
        // Select the role model through supported session creation, then run without an override.
        let selection = SHA256.hash(data: Data((workspace.path + "|" + model).utf8)).map { String(format: "%02x",$0) }.joined()
        let key = "agent:projectx:projectx-model:" + selection
        for _ in 0..<2 {
            try await sessions.ensure(key) { [rpc, agent] in
                let created = try await rpc.call("sessions.create",["key":key,"agentId":agent,"model":model,"permissionMode":"read-only"])
                guard created["ok"] as? Bool == true, created["key"] as? String == key else { throw ProjectError.uncertain("Secretary model-session selection unconfirmed; no inference dispatched.") }
            }
            let envelope = try await rpc.call("agent",["agentId":agent,"sessionKey":key,"message":prompt,"modelRun":true,"promptMode":"none","deliver":false,"timeout":90,"idempotencyKey":"projectx-" + identifier()],final: true,sourceMessageID: sourceMessageID)
            // A deleted/pruned role session silently runs the agent's default model: recreate it once (raw runs are stateless).
            let used = ((envelope["result"] as? [String:Any])?["meta"] as? [String:Any])?["agentMeta"] as? [String:Any]
            if used == nil || "\(used?["provider"] as? String ?? "")/\(used?["model"] as? String ?? "")" == model { return try text(envelope) }
            await sessions.forget(key)
        }
        throw HarnessError.modelMismatch("Gateway did not run the selected model \(model); its output was not used.")
    }
    public func route(_ input: RoutingInput, stronger: Bool) async throws -> Decision {
        let prompt = Prompts.routingPrompt(input,stronger: stronger)
        return try JSONDecoder().decode(Decision.self,from: Data(try await model(prompt,model: stronger ? settings().reviewModel : settings().secretaryModel,sourceMessageID: input.sourceMessageID).utf8))
    }
    public func run(_ input: WorkerInput, update: @escaping @Sendable (StreamUpdate) async throws -> Void, memory: @escaping @Sendable (MemoryCall) async throws -> String) async throws -> WorkerOutput {
        guard agent == "projectx", input.topic.sessionKey.hasPrefix("agent:projectx:projectx:") else { throw ProjectError.blocked("R1 workers must use app-owned sessions on the dedicated projectx agent. No private session import.") }
        let s = settings()
        if let executor = input.work.executor { return try await code(input,executor: executor,settings: s,update: update) }
        let key = input.topic.sessionKey; let controller = "agent:\(agent):projectx-control:\(input.topic.id)"
        // Workers run at full permission with the agent's default tools (owner, 2026-10-07). Creating once per topic per
        // app run also upgrades topic sessions created read-only before that. The CLI requests admin scope for "full".
        try await prepare(controller,model: s.workerModel,create: ["permissionMode":"guarded"],mcp: false)
        try await prepare(key,model: s.workerModel,create: ["permissionMode":"full"],mcp: true)
        _ = try await compactTopic(input,force: false,update: update)
        var wire = try Prompts.firstStep(input,settings: s,cuaSession: "yorozu-" + identifier().prefix(8))
        for step in 0...Prompts.memoryOperations {
            // Checked before the run ID is stamped: an oversized wire never dispatches; an overflow fails the work (also on later memory steps).
            guard wire.utf8.count <= workerGuard else { throw ProjectError.overflow("This step's input is too large to send (\(wire.utf8.count) bytes, limit \(workerGuard)).") }
            let runID = "projectx-run-" + identifier()
            try await update(.handle(RunHandle(sessionKey: key,controllerKey: controller,runID: runID)))
            let listener = await rpc.native?.observe { raw in
                if let event = Self.publicEvent(raw,session: key,run: runID,task: input.work.id) { try? await update(.event(event)) }
            }
            let result: [String:Any]
            do { result = try await rpc.call("agent",["agentId":agent,"sessionKey":key,"message":wire,"bootstrapContextMode":"lightweight","promptMode":"minimal","deliver":false,"disableMessageTool":true,"timeout":240,"idempotencyKey":runID],final: true,sourceMessageID: input.work.messageID) }
            catch { if let listener { await rpc.native?.removeObserver(listener) }; throw error }
            if let listener { await rpc.native?.removeObserver(listener) }
            // The CLI cannot stream; committed public messages of this exact run are projected once it ends.
            if let history = try? await rpc.call("chat.history",["sessionKey":key,"limit":10,"maxChars":64000]) {
                for event in Self.visibleEvents(history,task: input.work.id,run: runID) { try? await update(.event(event)) }
            }
            let answer: String
            do { answer = try text(result) } catch ProjectError.overflow {
                throw ProjectError.overflow(try await compactTopic(input,force: true,update: update) ? "This topic's session ran out of context. Yorozu compacted it, so asking again should now work." : "This topic's session is too long for the model and could not be compacted. Start a new topic for this request.")
            }
            switch try Prompts.workerReply(answer,step: step) {
            case .final(let output): return output
            case .memory(let call): wire = try await Prompts.memoryStep(call,eventID: runID + "-memory",task: input.work.id,update: update,memory: memory)
            }
        }; throw ProjectError.invalid("Worker invocation ended without an answer.")
    }
    public func steer(_ work: Work, topic: Topic, amendment: Amendment) async throws -> Bool {
        // Coding runs take changes as a follow-up turn of the same task and session (mid-run steering unverified).
        guard work.executor == nil else { return false }
        guard let controller = work.controllerKey else { return false }
        let result = try await rpc.call("tools.invoke",["name":"sessions_send","sessionKey":controller,"agentId":agent,"idempotencyKey":"\(work.id)-revision-\(amendment.revision)","args":["sessionKey":topic.sessionKey,"message":try encoded(amendment),"mode":"steer","timeoutSeconds":0,"watch":false]])
        let raw = result["output"] as? [String:Any] ?? [:]; let output = raw["details"] as? [String:Any] ?? raw
        return result["ok"] as? Bool == true && output["status"] as? String == "accepted" && output["targetDisposition"] as? String == "steered" && output["sessionKey"] as? String == topic.sessionKey
    }
    public func cancel(_ work: Work, topic: Topic) async throws -> Bool {
        guard let run = work.runID else { return true } // Never dispatched; setHandle refuses suppressed work.
        guard run.hasPrefix("projectx-") else { return true } // Another harness's run (a harness switch): nothing here to stop.
        let key = work.executor.map { codingKey(topic,$0) } ?? topic.sessionKey
        let r = try await rpc.call("chat.abort",["sessionKey":key,"agentId":agent,"runId":run,"preserveSideRuns":true])
        // aborted:false means no active, queued or pending run has this ID: nothing is left running.
        return (r["runIds"] as? [String] ?? []).contains(run) || r["aborted"] as? Bool == false
    }
    public func reconcile(_ work: Work, topic: Topic) async throws -> RunStatus {
        guard let run = work.runID else { return .unknown }
        guard run.hasPrefix("projectx-") else { return .stopped } // Another harness's run: not reachable from here.
        if let executor = work.executor { return try await reconcileCode(run,key: codingKey(topic,executor),revision: work.revision) }
        let r = try await rpc.call("agent.wait",["runId":run,"timeoutMs":1])
        guard r["runId"] as? String == run else { return .unknown }
        if r["status"] as? String == "pending" { return .running }
        let ended = (r["endedAt"] as? Double ?? 0) > 0 && r["pendingError"] as? Bool != true
        // agent.wait truncates terminalReply to 4096 chars and forgets runs ~10 min after they end (or on Gateway
        // restart). The session transcript keeps this exact run's full reply and its admitted user turn.
        // Previews only; the reply itself is read whole (`whole`).
        let messages = try await rpc.call("chat.history",["sessionKey":topic.sessionKey,"limit":10,"maxChars":2000])["messages"] as? [[String:Any]] ?? []
        if let reply = messages.last(where: { $0["role"] as? String == "assistant" && ($0["__openclaw"] as? [String:Any])?["runId"] as? String == run }) {
            guard let full = try? await whole(reply,key: topic.sessionKey) else { return .unknown }
            let text = (full["content"] as? [[String:Any]])?.last(where: { $0["type"] as? String == "text" })?["text"] as? String
            if let text, let final = try? JSONDecoder().decode(WorkerOutput.self,from: Data(text.utf8)), !final.text.isEmpty, final.appliedRevision >= 0 { return .completed(final) }
            // Tool-using runs commit tool-call messages mid-run. Only a non-tool stop, a known end or 15 min of silence settles it.
            guard ["toolUse","tool_use"].contains(reply["stopReason"] as? String ?? ""), !ended else { return .stopped }
            return Date().timeIntervalSince1970 - (reply["timestamp"] as? Double ?? 0) / 1000 > 900 ? .stopped : .unknown
        }
        if ended { return .stopped }
        // No reply. Never admitted => no "<run>:user" turn. Admitted but silent for 15 min => gone (worker timeout is 240 s).
        guard let turn = messages.last(where: { $0["idempotencyKey"] as? String == run + ":user" }) else { return .stopped }
        return Date().timeIntervalSince1970 - (turn["timestamp"] as? Double ?? 0) / 1000 > 900 ? .stopped : .unknown
    }
    public func extract(_ message: Message, existing: [MemoryHit]) async throws -> [MemoryProposal] {
        if sensitive(message.body) { return [] }
        let prompt = try Prompts.extractionPrompt(message,existing: existing,cap: rawPromptCap)
        let reply = try await model(prompt,model: settings().extractionModel,sourceMessageID: message.id)
        do { return try JSONDecoder().decode([MemoryProposal].self,from: Data(reply.utf8)) }
        catch { throw ProjectError.invalid("Extraction reply is not a valid proposal array (\(reply.utf8.count) bytes): \(utf8Prefix(String(describing: error),bytes: 300))") }
    }
    /// Only actual public lifecycle/tool-name facts for the exact locally owned run. No text deltas, reasoning or arguments.
    public static func publicEvent(_ raw: String, session: String, run: String, task: String) -> WorkerEvent? {
        guard let frame = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String:Any], frame["event"] as? String == "agent", let p = frame["payload"] as? [String:Any], p["runId"] as? String == run, let seq = p["seq"] as? Int, seq >= 0, let data = p["data"] as? [String:Any] else { return nil }
        if let key = p["sessionKey"] as? String, key != session { return nil }
        let body: String; let kind: String
        if p["stream"] as? String == "lifecycle", let phase = data["phase"] as? String, ["start","end","error"].contains(phase) { body = "Worker lifecycle: " + phase; kind = "lifecycle" }
        // One row per call, from its start (only the start carries args). A call made through tool_call also arrives as its
        // own event with parentToolCallId; the tool_call row already names it.
        else if p["stream"] as? String == "tool", data["phase"] as? String == "start", data["parentToolCallId"] == nil, let name = data["name"] as? String, name.count <= 100, case let row = toolRow(name,args: data["args"]), !sensitive(row) { body = row; kind = "tool" }
        else { return nil }
        return WorkerEvent(id: task + ":" + run + ":event:\(seq)",taskID: task,kind: kind,body: body,created: (p["ts"] as? Double ?? 0) / 1000) // Gateway ts is epoch ms.
    }
    /// Committed public messages of one exact run. Worker contract JSON (final answer, memoryCall) is not progress.
    public static func visibleEvents(_ history: [String:Any], task: String, run: String) -> [WorkerEvent] {
        var events: [WorkerEvent] = []
        for message in history["messages"] as? [[String:Any]] ?? [] {
            let metadata = message["__openclaw"] as? [String:Any] ?? [:]
            guard message["role"] as? String == "assistant", metadata["runId"] as? String == run, let source = metadata["id"] as? String ?? message["id"] as? String, !["analysis","reasoning"].contains(message["channel"] as? String ?? "") else { continue }
            for (i,block) in (message["content"] as? [[String:Any]] ?? []).enumerated() {
                let type = block["type"] as? String ?? ""; var body: String?; var kind = "message"
                if type == "text", !["analysis","reasoning"].contains(block["channel"] as? String ?? ""), let text = block["text"] as? String {
                    let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String:Any]
                    if object?["memoryCall"] == nil && object?["appliedRevision"] == nil { body = text }
                }
                if ["toolCall","tool_use"].contains(type), block["parentToolCallId"] == nil, let name = block["name"] as? String, name.count <= 100 { body = toolRow(name,args: block["arguments"] ?? block["input"]); kind = "tool" }
                guard let text = body, !sensitive(text), text.utf8.count <= 16000 else { continue }
                events.append(WorkerEvent(id: task + ":" + source + ":\(i)",taskID: task,kind: kind,body: text,created: (message["timestamp"] as? Double ?? 0) / 1000)) // epoch ms
            }
        }; return events
    }
}
/// sessions.create once per key per app run; concurrent first uses share one call, failures retry next time.
actor SessionCreations {
    private var tasks: [String:Task<Void,Error>] = [:]
    func ensure(_ key: String, _ create: @escaping @Sendable () async throws -> Void) async throws {
        let task = tasks[key] ?? Task { try await create() }
        tasks[key] = task
        do { try await task.value } catch { if tasks[key] == task { tasks[key] = nil }; throw error }
    }
    func forget(_ key: String) { tasks[key] = nil }
    /// What `prepare` last applied to a session this app run (model, runtime, MCP overlay).
    private var applied: [String:String] = [:]
    func applied(_ key: String) -> String? { applied[key] }
    func setApplied(_ key: String,_ value: String) { applied[key] = value }
}
/// The overlay of the last mirrored MCP list, shared by concurrent uses; a changed list mirrors again, a failure retries.
actor MCPMirror {
    private var last: (list: [String:MCPServer], task: Task<[String:Bool],Error>)?
    func overlay(_ list: [String:MCPServer],_ make: @escaping @Sendable () async throws -> [String:Bool]) async throws -> [String:Bool] {
        let task = last.flatMap { $0.list == list ? $0.task : nil } ?? Task { try await make() }
        last = (list,task)
        do { return try await task.value } catch { if last?.task == task { last = nil }; throw error }
    }
}

// MARK: - MCP servers: Yorozu's list mirrored into OpenClaw as `yorozu-<name>` entries, off for every other session.
extension OpenClawHarness {
    /// Once per distinct list: write changed entries into mcp.servers with enabled:false (the Gateway hot-reloads mcp.*),
    /// then return the overlay that turns on exactly Yorozu's servers and off every other server configured at that moment.
    func mcpOverlay() async throws -> [String:Bool] {
        guard let list = settings().mcpServers else { return [:] }
        return try await mcp.overlay(list) { [rpc] in
            let snapshot = try await rpc.call("config.get",[:])
            guard let hash = snapshot["hash"] as? String else { throw ProjectError.uncertain("OpenClaw config hash unavailable; MCP servers not set up.") }
            let configured = ((snapshot["config"] as? [String:Any])?["mcp"] as? [String:Any])?["servers"] as? [String:Any] ?? [:]
            var patch: [String:Any] = [:], replace: [String] = []
            for (name,server) in list {
                let key = "yorozu-" + name, entry: [String:Any] = ["command":server.command,"args":server.args ?? [],"enabled":false]
                guard !NSDictionary(dictionary: entry).isEqual(configured[key] as? [String:Any] ?? [:]) else { continue }
                patch[key] = entry
            }
            for key in configured.keys where key.hasPrefix("yorozu-") && list[String(key.dropFirst(7))] == nil { patch[key] = NSNull() }
            if !patch.isEmpty {
                // A merge patch; OpenClaw refuses to shrink or drop an array unless its exact path is in replacePaths.
                for key in patch.keys { replace += Self.arrayPaths(configured[key] as Any,"mcp.servers." + key) }
                // No `note`: it would leave a restart sentinel that wakes the owner's main agent on the next Gateway start.
                // A concurrent config edit fails the hash check; the next use retries.
                let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["mcp":["servers":patch]]),as: UTF8.self)
                let patched = try await rpc.call("config.patch",["raw":raw,"baseHash":hash,"replacePaths":replace])
                guard patched["ok"] as? Bool == true else { throw ProjectError.uncertain("OpenClaw did not confirm the MCP server update.") }
            }
            var overlay = configured.mapValues { _ in false }
            for name in list.keys { overlay["yorozu-" + name] = true }
            return overlay
        }
    }
    private static func arrayPaths(_ value: Any,_ path: String) -> [String] {
        value is [Any] ? [path] : (value as? [String:Any])?.flatMap { arrayPaths($0.value,path + "." + $0.key) } ?? []
    }
    /// Before each use of a topic, controller or coding session: bring it to `model` (and `runtime`) with sessions.patch
    /// (operator.write), never by re-creating it, since sessions.create with another model on an existing key needs
    /// operator.admin; create it once per app run; then apply the MCP overlay. Embedded and Codex runs read the overlay each
    /// turn; claude-cli runs ignore it (OpenClaw 2026.9.6 does not pass session toolOverrides to the CLI runner). Gateway
    /// calls happen only when the wanted state differs from what this app run last applied to the key.
    func prepare(_ key: String,model: String,runtime: String? = nil,create: [String:any Sendable],mcp: Bool) async throws {
        guard !model.isEmpty else { throw ProjectError.blocked("No model is set for this work; choose one in Settings › Advanced.") }
        let overlay = mcp ? try await mcpOverlay() : [:]
        let wanted = "\(model)|\(runtime ?? "")|" + overlay.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        guard await sessions.applied(key) != wanted else { return }
        // session is null for a key that does not exist yet.
        let row = try await rpc.call("sessions.describe",["key":key,"agentId":agent])["session"] as? [String:Any]
        if let row, "\(row["modelProvider"] as? String ?? "")/\(row["model"] as? String ?? "")" != model || (runtime != nil && (row["agentRuntime"] as? [String:Any])?["id"] as? String != runtime) {
            // A model its runtime cannot run silently drops the runtime unless both are sent (then the Gateway refuses it).
            var patch: [String:Any] = ["key":key,"agentId":agent,"model":model]; if let runtime { patch["agentRuntime"] = runtime }
            let r = try await rpc.call("sessions.patch",patch); let e = r["entry"] as? [String:Any] ?? [:]
            guard r["ok"] as? Bool == true, "\(e["providerOverride"] as? String ?? "")/\(e["modelOverride"] as? String ?? "")" == model, runtime == nil || e["agentRuntimeOverride"] as? String == runtime else { throw ProjectError.uncertain("Gateway did not confirm switching this session to \(model); nothing was run.") }
        }
        try await sessions.ensure(key) { [rpc, agent] in
            var params: [String:Any] = create.merging(["key":key,"agentId":agent,"model":model]) { $1 }; if let runtime { params["agentRuntime"] = runtime }
            let created = try await rpc.call("sessions.create",params)
            guard created["ok"] as? Bool == true, created["key"] as? String == key else { throw ProjectError.uncertain("Gateway did not confirm creating session \(key).") }
        }
        let current = row?["toolOverrides"] as? [String:Any] // none on a session created just now
        if !overlay.isEmpty, !NSDictionary(dictionary: overlay).isEqual(current?["mcpServers"] as? [String:Any] ?? [:]) {
            // The overlay is replaced whole: keep the owner's other per-session fields (mcpToolsDeny, skills, webSearch).
            var next = current ?? [:]; next["mcpServers"] = overlay
            let patched = try await rpc.call("sessions.patch",["key":key,"agentId":agent,"toolOverrides":next,"expectedToolOverrides":current ?? NSNull()])
            guard patched["ok"] as? Bool == true, patched["key"] as? String == key else { throw ProjectError.uncertain("MCP servers for this session unconfirmed.") }
        }
        await sessions.setApplied(key,wanted)
    }
}

// MARK: - Context budgets: compaction of thinking topic sessions (owner decisions 1–2, 5).
extension OpenClawHarness {
    /// Usable window: the session's configured `contextTokens`, at most the 258,400 tokens the pool models really take.
    static let usableWindow = 258_400
    /// `sessions.describe`: the session's transcript id and last-turn token count (nil unless the Gateway marks it fresh).
    func sessionMark(_ key: String) async throws -> (id: String?, tokens: Int?, window: Int) {
        let s = try await rpc.call("sessions.describe",["key":key,"agentId":agent])["session"] as? [String:Any] ?? [:]
        return (s["sessionId"] as? String, s["totalTokensFresh"] as? Bool == true ? s["totalTokens"] as? Int : nil, min(s["contextTokens"] as? Int ?? Self.usableWindow,Self.usableWindow))
    }
    /// At half the usable window (or when `force`d after an overflow), `sessions.compact` as its own call, never inside the
    /// 240 s run. The Gateway refuses it while the session has an active or queued run. A compaction is noted in the
    /// sub-chat; a failure goes to the main timeline and the task continues. True when the session was compacted.
    func compactTopic(_ input: WorkerInput,force: Bool,update: @escaping @Sendable (StreamUpdate) async throws -> Void) async throws -> Bool {
        let key = input.topic.sessionKey; let before: Int?; let after: Int?
        // An unreadable count is no reason to compact (or to post a notice) unless an overflow forces it.
        let mark = try? await sessionMark(key)
        guard force || mark.map({ ($0.tokens ?? 0) * 2 >= $0.window }) == true else { return false }
        do {
            // ok:false ("Nothing to compact", runner failures) comes back with its reason; see GatewayRPC.perform.
            let r = try await rpc.call("sessions.compact",["key":key,"agentId":agent])
            guard r["compacted"] as? Bool == true else { throw ProjectError.uncertain(r["reason"] as? String ?? "not compacted") }
            before = ((r["result"] as? [String:Any])?["tokensBefore"] as? Int) ?? mark?.tokens; after = (r["result"] as? [String:Any])?["tokensAfter"] as? Int
        } catch {
            try await update(.notice("Couldn't compact the session of topic “\(input.topic.label)”: \(utf8Prefix(error.localizedDescription,bytes: 300))"))
            return false
        }
        let sizes = before.map { b in after.map { "\(b) → \($0) tokens" } ?? "from \(b) tokens" } ?? ""
        try await update(.event(WorkerEvent(id: input.work.id + ":compaction:" + identifier(),taskID: input.work.id,kind: "compaction",body: "Compacted this topic's session" + (sizes.isEmpty ? "." : ": " + sizes),created: Date().timeIntervalSince1970)))
        return true
    }
}

// MARK: - R2 coding workers: Claude Code (claude-cli) or Codex inside openclaw sessions, each in a managed git worktree.
extension OpenClawHarness {
    func codingKey(_ topic: Topic,_ executor: String) -> String { topic.sessionKey + "-" + executor }
    /// Once per app run per topic and tool. Claude Code needs "full" (its guarded modes need an approval client PROJECTX
    /// lacks); Codex "workspace" is seatbelt-confined to the worktree. Branch: openclaw/<label>-<id>-<tool>, from the base branch.
    private func codingSession(_ topic: Topic,_ executor: String,model: String,base: String) async throws -> String {
        let key = codingKey(topic,executor)
        let slug = topic.label.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }
            .joined().split(separator: "-").joined(separator: "-").prefix(32)
        let name = (slug.isEmpty ? "" : slug + "-") + topic.id.prefix(6) + "-" + executor
        let (runtime,permission) = executor == "codex" ? ("codex","workspace") : ("claude-cli","full")
        try await prepare(key,model: model,runtime: runtime,create: ["permissionMode":permission,"worktree":true,"worktreeBaseRef":base,"worktreeName":name],mcp: true)
        return key
    }
    /// Async dispatch (no 240 s cap), then poll: agent.wait blocks up to 20 s per check; committed messages, commands and
    /// output tails go to the sub-chat. The final reply plus the worktree diffstat is the result.
    func code(_ input: WorkerInput,executor: String,settings s: HarnessSettings,update: @escaping @Sendable (StreamUpdate) async throws -> Void) async throws -> WorkerOutput {
        // Open question 11: without a dev repo, coding work ends with a plain notice before anything is created or sent.
        guard let repo = s.devRepo else { throw ProjectError.blocked("No repository is set for coding work. Set a repository in Settings › Advanced.") }
        guard let tool = executors.first(where: { $0.id == executor })?.name else { throw HarnessError.notReady("OpenClaw offers no coding executor \"\(executor)\".") }
        let runID = "projectx-code-" + identifier(); let handle = RunHandle(sessionKey: codingKey(input.topic,executor),controllerKey: "",runID: runID)
        // The run marker anchors reconcile to this run's own user turn in the session transcript.
        let message = Prompts.codingMessage(input,contract: Prompts.codingContract(executor: tool,repo: repo,settings: s,cuaSession: "yorozu-" + identifier().prefix(8)),runID: runID)
        // Contract ~5 KB + instruction and user message ≤ 6000 B each + history ≤ 6000 B. Checked before the handle is stamped.
        guard message.utf8.count <= workerGuard else { throw ProjectError.overflow("The coding task message is \(message.utf8.count) bytes, over the \(workerGuard)-byte cap; shorten the request or start a new topic.") }
        let key = try await codingSession(input.topic,executor,model: s.codingModels[executor] ?? "",base: s.codingBaseBranch)
        try await update(.handle(handle))
        let earlier = Set(Self.messageIDs((try? await rpc.call("chat.history",["sessionKey":key,"limit":20,"maxChars":200])) ?? [:]))
        let mark = try? await sessionMark(key)
        let started = try await rpc.call("agent",["agentId":agent,"sessionKey":key,"message":message,"deliver":false,"timeout":7200,"idempotencyKey":runID],sourceMessageID: input.work.messageID)
        guard started["runId"] as? String == runID else { throw ProjectError.uncertain("\(tool) run start unconfirmed. Request ID: \(runID)") }
        var lost = 0, failures = 0, unread = 0
        while true {
            try Task.checkCancellation()
            // Re-asserting the handle throws once the work is suppressed, so a stop is noticed within one poll even if
            // its first abort raced the run's admission; execute() then re-sends the abort and settles the stop.
            try await update(.handle(handle))
            // Gateway restarts and busy answers are transient while the run keeps going; only a long outage ends tracking.
            guard let r = try? await rpc.call("agent.wait",["runId":runID,"timeoutMs":20000]) else {
                failures += 1
                if failures >= 40 { throw ProjectError.uncertain("Gateway unreachable for about 10 min while \(tool) was running; it may still be active. Its worktree keeps any uncommitted changes; ask to retry.") }
                try await Task.sleep(for: .seconds(15)); continue
            }
            failures = 0
            let fetched = try? await rpc.call("chat.history",["sessionKey":key,"limit":20,"maxChars":2000])
            for event in Self.codingEvents(fetched ?? [:],task: input.work.id,skip: earlier) { try? await update(.event(event)) }
            if (r["endedAt"] as? Double ?? 0) > 0 {
                // agent.wait carries only the error text, no kind: match the Gateway's overflow wording (packages/ai/src/utils/overflow.ts).
                if r["status"] as? String != "ok", let error = r["error"] as? String, error.range(of: "context.*overflow|context window.*(too (large|long)|exceed|over|limit|max)|context.?length|prompt.*too (large|long)|maximum context|compaction fail|request_too_large|too many tokens|token limit exceeded",options: [.regularExpression,.caseInsensitive]) != nil, error.range(of: "too small",options: .caseInsensitive) == nil {
                    throw ProjectError.overflow("\(tool)'s session ran out of context. Changes so far stay uncommitted in its worktree; start a new topic for this work.")
                }
                guard r["status"] as? String == "ok" else { throw ProjectError.invalid("\(tool) run ended: \(r["status"] as? String ?? "unknown"). Changes so far stay uncommitted in its worktree.") }
                break
            }
            // A bare timeout is in-flight, unknown or forgotten; only a successfully read session state tells them apart.
            guard let history = fetched else {
                unread += 1
                if unread >= 15 { throw ProjectError.uncertain("\(tool) run status unknown: session history unavailable. It may still be running; reconcile before retry.") }
                continue
            }
            unread = 0
            let info = history["sessionInfo"] as? [String:Any] ?? [:]
            let active = r["status"] as? String == "pending" || (info["activeRunIds"] as? [String] ?? []).contains(runID) || info["hasActiveRun"] as? Bool == true
            lost = active ? 0 : lost + 1
            if lost >= 3 { throw ProjectError.uncertain("\(tool) run is no longer tracked by the Gateway. Its worktree keeps any uncommitted changes; ask to retry.") }
        }
        // Decision 5: the tool compacts its own session. OpenClaw exposes no compaction count, so a new transcript id or
        // a smaller fresh token count than before the run is taken as one.
        if let mark, let now = try? await sessionMark(key), (mark.id != nil && now.id != nil && now.id != mark.id) || (now.tokens ?? .max) < (mark.tokens ?? 0) {
            let sizes = mark.tokens.flatMap { b in now.tokens.map { ": \(b) → \($0) tokens" } } ?? "."
            try? await update(.event(WorkerEvent(id: input.work.id + ":" + runID + ":compaction",taskID: input.work.id,kind: "compaction",body: "\(tool) compacted its session" + sizes,created: Date().timeIntervalSince1970)))
        }
        let full = (try? await rpc.call("chat.history",["sessionKey":key,"limit":20,"maxChars":2000])) ?? [:]
        var text = try await finalText(full,key: key,skip: earlier) ?? "\(tool) finished without a summary."
        // Only what the worker left uncommitted (the default scope compares to origin/main); a committed change reads as 0 files.
        if let diff = try? await rpc.call("sessions.diff",["sessionKey":key,"agentId":agent,"scope":"uncommitted"]) {
            let files = (diff["files"] as? [[String:Any]] ?? []).compactMap { $0["path"] as? String }
            let line = "Worktree \(diff["root"] as? String ?? "?") (branch \(diff["branch"] as? String ?? "?"), uncommitted) · \(files.count) file(s) · +\(diff["additions"] as? Int ?? 0) −\(diff["deletions"] as? Int ?? 0)" + (diff["truncated"] as? Bool == true ? " (truncated)" : "")
            try? await update(.event(WorkerEvent(id: input.work.id + ":" + runID + ":diff",taskID: input.work.id,kind: "diff",body: ([line] + files.prefix(20)).joined(separator: "\n"),created: Date().timeIntervalSince1970)))
            text += "\n\n" + line
        }
        return WorkerOutput(text: text,appliedRevision: input.work.revision)
    }
    /// Anchored to this run's own user turn (claude-cli transcripts carry no runId, and agent.wait forgets runs after
    /// ~10 min), so a run that finished while the app was closed is delivered instead of re-run.
    func reconcileCode(_ run: String,key: String,revision: Int) async throws -> RunStatus {
        let r = (try? await rpc.call("agent.wait",["runId":run,"timeoutMs":1])) ?? [:]
        if r["status"] as? String == "pending" { return .running }
        // 8000 chars keep the "[run …]" marker, after the ~5 KB contract, in a user turn's preview.
        guard let history = try? await rpc.call("chat.history",["sessionKey":key,"limit":200,"maxChars":8000]) else { return .unknown }
        let info = history["sessionInfo"] as? [String:Any] ?? [:]
        if (info["activeRunIds"] as? [String] ?? []).contains(run) || info["hasActiveRun"] as? Bool == true { return .running }
        let messages = history["messages"] as? [[String:Any]] ?? []
        guard let anchor = messages.lastIndex(where: { $0["idempotencyKey"] as? String == run + ":user" || ($0["role"] as? String == "user" && "\($0["content"] ?? "")".contains("[run \(run)]")) }) else { return .stopped }
        let after = Array(messages[(anchor + 1)...])
        if (r["endedAt"] as? Double ?? 0) > 0, r["status"] as? String != "ok" { return .stopped }
        // Only a final turn (not a crashed run's mid-step narration) counts as this run's answer.
        guard let last = after.last(where: { $0["role"] as? String == "assistant" }), !["toolUse","tool_use"].contains(last["stopReason"] as? String ?? ""),
              let text = try await finalText(["messages":after],key: key,skip: []) else { return .stopped }
        return .completed(WorkerOutput(text: text,appliedRevision: revision))
    }
    static func messageIDs(_ history: [String:Any]) -> [String] { (history["messages"] as? [[String:Any]] ?? []).compactMap(messageID) }
    static func messageID(_ m: [String:Any]) -> String? {
        (m["__openclaw"] as? [String:Any])?["id"] as? String ?? m["idempotencyKey"] as? String ?? (m["timestamp"] as? Double).map { "t\(Int($0))" }
    }
    /// The newest assistant reply with text, read whole: no Yorozu cut; past the Gateway's own caps its marker shows as is.
    func finalText(_ history: [String:Any],key: String,skip: Set<String>) async throws -> String? {
        let replyText = { (m: [String:Any]) in (m["content"] as? [[String:Any]] ?? []).filter { ($0["type"] as? String)?.lowercased() == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        guard let reply = (history["messages"] as? [[String:Any]] ?? []).last(where: { $0["role"] as? String == "assistant" && !skip.contains(Self.messageID($0) ?? "") && !replyText($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return replyText(try await whole(reply,key: key))
    }
    /// chat.history marks a preview `__openclaw.truncated` (text past maxChars ends "…(truncated)…"; a message over 128 KiB
    /// becomes a placeholder); chat.message.get returns it whole, up to 1,000,000 chars per text field. Else the preview.
    /// A failed fetch throws (status unknown, reconcile later) rather than passing a preview off as the answer; only the
    /// Gateway's own "oversized" refusal keeps the preview with its marker.
    func whole(_ m: [String:Any],key: String) async throws -> [String:Any] {
        let meta = m["__openclaw"] as? [String:Any] ?? [:]
        guard meta["truncated"] as? Bool == true, let id = meta["id"] as? String else { return m }
        let r = try await rpc.call("chat.message.get",["sessionKey":key,"agentId":agent,"messageId":id,"maxChars":1_000_000])
        if let message = r["message"] as? [String:Any] { return message }
        if r["unavailableReason"] as? String == "oversized" { return m }
        throw ProjectError.uncertain("The full reply could not be read yet; its run finished. Reconcile before retry.")
    }
    /// Public progress only: assistant text, shell commands, tool names with paths, and output tails. Never reasoning.
    static func codingEvents(_ history: [String:Any],task: String,skip: Set<String>) -> [WorkerEvent] {
        var events: [WorkerEvent] = []
        for message in history["messages"] as? [[String:Any]] ?? [] {
            guard message["role"] as? String == "assistant", let id = messageID(message), !skip.contains(id) else { continue }
            let created = (message["timestamp"] as? Double ?? 0) / 1000 // epoch ms
            for (i,block) in (message["content"] as? [[String:Any]] ?? []).enumerated() {
                let type = (block["type"] as? String ?? "").lowercased(); var body: String?; var kind = "message"
                if type == "text" { body = block["text"] as? String }
                else if ["toolcall","tool_use"].contains(type), block["parentToolCallId"] == nil {
                    let args = block["arguments"] as? [String:Any] ?? block["input"] as? [String:Any] ?? [:]; let name = toolRow(String((block["name"] as? String ?? "tool").prefix(100)),args: args)
                    if let command = args["command"] as? String { body = "$ " + String(command.prefix(2000)); kind = "command" }
                    else { let path = (args["file_path"] ?? args["path"]) as? String; body = name + (path.map { " " + $0 } ?? ""); kind = "tool" }
                } else if type == "tool_result" {
                    let content = block["content"] as? String ?? (block["content"] as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    body = String(content.suffix(2000)); kind = block["is_error"] as? Bool == true ? "error" : "output"
                }
                guard let text = body?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !sensitive(text) else { continue }
                events.append(WorkerEvent(id: task + ":" + id + ":\(i)",taskID: task,kind: kind,body: text,created: created))
            }
        }
        return events
    }
}

/// At most `bytes` UTF-8 bytes of `s`, cut on a Unicode scalar boundary.
public func utf8Prefix(_ s: String, bytes: Int) -> String {
    guard s.utf8.count > bytes else { return s }
    var i = s.utf8.index(s.startIndex,offsetBy: max(bytes,0))
    while i.samePosition(in: s.unicodeScalars) == nil { i = s.utf8.index(before: i) }
    return String(s.unicodeScalars[..<i])
}
/// At most `bytes` UTF-8 bytes of `s`: head and tail on scalar boundaries around a visible "[… cut]" marker.
func utf8Excerpt(_ s: String, bytes: Int) -> String {
    let marker = "\n[… cut]\n"
    guard s.utf8.count > bytes else { return s }
    guard bytes > marker.utf8.count * 2 else { return utf8Prefix(s,bytes: bytes) }
    let half = (bytes - marker.utf8.count) / 2
    var i = s.utf8.index(s.endIndex,offsetBy: -half)
    while i.samePosition(in: s.unicodeScalars) == nil { i = s.utf8.index(after: i) }
    return utf8Prefix(s,bytes: half) + marker + String(s.unicodeScalars[i...])
}
