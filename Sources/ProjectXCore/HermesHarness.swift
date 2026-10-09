import Foundation

/// Read-only Hermes detection for setup and Settings (#317). Hermes is ready when `problems` is empty; `warnings`
/// (an untested version) never block.
public struct HermesReadiness: Sendable, Equatable {
    public var launcher: String?
    public var version: String?
    public var tested = false
    public var problems: [String] = [], warnings: [String] = []
    public var ready: Bool { problems.isEmpty }
}

/// Hermes's setup seam (#317): `HermesHarness.readiness()` as readiness items. Its setup steps are #318's
/// (`HermesProfiles`); here only detection.
public struct HermesSetup: HarnessSetup {
    public var kind: Config.HarnessKind { .hermes }
    public var title: String { "Hermes Agent" }
    public var steps: [String] { ["harness"] }
    public var url: String, agent: String
    public init(url: String, agent: String) { self.url = url; self.agent = agent }
    public var installed: Bool { HermesHarness.launcher() != nil }
    public func detect() async -> HarnessDetection {
        var d = HarnessDetection(kind: kind,title: title)
        guard let harness = try? HermesHarness(url: url,agent: agent) else {
            d.items = [Readiness.Item(id: "hermes.url",title: String(localized: "Hermes's address in config.toml isn't usable"),detail: url,severity: .warning,fix: .step("harness"))]; return d
        }
        let r = await harness.readiness()
        d.installed = r.launcher != nil; d.version = r.version; d.reachable = d.installed ? r.version != nil : nil
        guard let launcher = r.launcher else {
            d.items = [Readiness.Item(id: "hermes.installed",title: String(localized: "Hermes Agent isn't installed"),detail: r.problems.joined(separator: "\n"),severity: .blocking,fix: .open(title: String(localized: "How to install Hermes Agent"),url: URL(string: "https://hermes-agent.nousresearch.com")!))]; return d
        }
        d.items = [Readiness.Item(id: "hermes.installed",title: String(localized: "Hermes Agent is installed"),detail: launcher + (r.version.map { " " + $0 } ?? ""),severity: .ok)]
            + r.problems.enumerated().map { Readiness.Item(id: "hermes.problem.\($0.offset)",title: String(localized: "Hermes Agent isn't ready"),detail: $0.element,severity: .warning,fix: .step("harness")) }
            + r.warnings.enumerated().map { Readiness.Item(id: "hermes.warning.\($0.offset)",title: String(localized: "This Hermes Agent version hasn't been tested with Yorozu"),detail: $0.element,severity: .warning) }
        return d
    }
    public func executors(_ settings: HarnessSettings) -> [CodingExecutor] {
        ((try? HermesHarness(url: url,agent: agent,settings: { settings }))?.executors ?? []).map { CodingExecutor(executor: $0,binary: "hermes",path: HermesHarness.launcher()) }
    }
}

/// Nous Research's Hermes Agent through its loopback API server (#318; docs/hermes-integration.md). Roles run as fresh
/// one-shot runs in profile `yorozu-roles`; workers run in `yorozu-worker`, one session per topic (`yorozu-<topic id>`)
/// and one per topic for coding (`yorozu-<topic id>-hermes`). Every run names provider and model, and a run served by any
/// other pair is discarded.
///
/// RunHandle mapping: `runID` is Yorozu's run id, stamped before the POST and sent as `Idempotency-Key`;
/// `controllerKey` is `hermes:<Yorozu run id>:<server run id>` once Hermes answers (`…:refused` when it refused the run
/// outright, so nothing ran); `sessionKey` is the Hermes session id.
public struct HermesHarness: Harness {
    public let id = "hermes"
    public let name = "Hermes Agent"
    public static let testedVersions = ["0.21.6"]
    public static let workerProfile = "yorozu-worker", rolesProfile = "yorozu-roles"
    public static let requiredFeatures = ["run_status", "run_events_sse", "run_stop", "run_steer", "session_model_lock", "tool_progress_events", "model_options"]
    static let roleTimeout = 120.0
    /// Hermes has no counterpart limits: the shared raw-prompt cap, less the role framing that rides along in
    /// `instructions`, so the Engine's routing trim (measured on the shared prompt) still fits; `workerGuard` is the default.
    public var rawPromptCap: Int { ProjectXCore.rawPromptCap - Self.roleOverhead }
    public var settings: @Sendable () -> HarnessSettings
    let client: HermesClient
    /// Request receipts (harness "hermes"): written before each `POST /v1/runs`; a failed write sends nothing.
    let audit: RequestAudit?
    private let state = HermesState()

    /// `[harness] agent`, only for topic keys, so topics made here continue after a switch to OpenClaw.
    public let agentID: String
    /// `url`: the Hermes API server root (loopback only); profiles are served under `/p/<profile>/`.
    public init(url: String = "http://127.0.0.1:8642", agent: String = "yorozu", audit: RequestAudit? = nil, settings: @escaping @Sendable () -> HarnessSettings = { HarnessSettings() }) throws {
        client = try HermesClient(url); agentID = agent; self.audit = audit; self.settings = settings
    }

    public var executors: [Executor] {
        [Executor(id: "hermes", name: "Hermes", appAccess: true, liveSteer: true, runtime: "hermes",
                  routingNotes: "Hermes runs its own agent loop with Yorozu's MCP servers, so it can operate apps and browsers, takes changes mid-run, and works in its own git worktree of the dev repo. Claude Code and Codex are not available under Hermes.",
                  notReady: settings().devRepo == nil ? "No repository is set for coding work." : nil)]
    }

    // MARK: Readiness

    /// The hermes launcher on PATH or at `~/.local/bin/hermes`.
    static func launcher() -> String? {
        let fm = FileManager.default, path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("hermes").path }
        return (path + [fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hermes").path]).first { fm.isExecutableFile(atPath: $0) }
    }
    public func readiness() async -> HermesReadiness {
        var r = HermesReadiness(), fm = FileManager.default
        let hermes = fm.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        r.launcher = Self.launcher()
        if r.launcher == nil { r.problems.append("The hermes launcher was not found on PATH or at ~/.local/bin/hermes. Install Hermes Agent.") }
        if !fm.fileExists(atPath: hermes.path) { r.problems.append("~/.hermes does not exist. Install Hermes Agent.") }
        for p in [Self.workerProfile, Self.rolesProfile] {
            guard fm.fileExists(atPath: hermes.appendingPathComponent("profiles/" + p).path) else { r.problems.append("Hermes profile \(p) does not exist. Run the Hermes setup step."); continue }
            // Unauthenticated liveness probe; then the authenticated feature flags.
            guard let (code, health) = try? await client.call(p, "GET", "/health", auth: false), code == 200, health["platform"] as? String == "hermes-agent" else {
                r.problems.append("Hermes's API server does not answer for profile \(p). Start `hermes gateway` with the API server on."); continue
            }
            r.version = health["version"] as? String ?? r.version
            do {
                let (code, caps) = try await client.call(p, "GET", "/v1/capabilities")
                guard code == 200 else { throw HermesClient.failure(code, caps, profile: p, doing: "list its capabilities") }
                let features = caps["features"] as? [String:Any] ?? [:]
                let missing = Self.requiredFeatures.filter { features[$0] as? Bool != true }
                if !missing.isEmpty { r.problems.append("Hermes (profile \(p)) lacks " + missing.joined(separator: ", ") + ".") }
            } catch { r.problems.append(error.localizedDescription) }
        }
        if let v = r.version {
            r.tested = Self.testedVersions.contains(v.hasPrefix("v") ? String(v.dropFirst()) : v)
            if !r.tested { r.warnings.append("Hermes \(v) has not been tested with Yorozu (tested: " + Self.testedVersions.joined(separator: ", ") + ").") }
        }
        return r
    }

    // MARK: Models

    /// `GET /api/model/options` of both profiles: models listed by both (each role runs in one of them). Price is input
    /// plus output $/Mtok ("$3.00"; "free" or unknown is nil); the payload has no context window or input kinds.
    public func models() async throws -> (allowed: [ModelInfo], primary: String?) {
        var lists: [[ModelInfo]] = [], primary: String?
        for p in [Self.workerProfile, Self.rolesProfile] {
            let (code, json) = try await client.call(p, "GET", "/api/model/options?include_unconfigured=false")
            guard code == 200 else { throw HermesClient.failure(code, json, profile: p, doing: "list its models") }
            if p == Self.workerProfile, let provider = json["provider"] as? String, let model = json["model"] as? String, !provider.isEmpty, !model.isEmpty { primary = provider + "/" + model }
            let price = { (s: Any?) in (s as? String).flatMap { $0.hasPrefix("$") ? Double($0.dropFirst()) : nil } }
            lists.append((json["providers"] as? [[String:Any]] ?? []).filter { $0["authenticated"] as? Bool != false }.flatMap { row -> [ModelInfo] in
                guard let slug = row["slug"] as? String else { return [] }
                let pricing = row["pricing"] as? [String:[String:Any]] ?? [:]
                return (row["models"] as? [String] ?? []).map { m in
                    ModelInfo(id: slug + "/" + m, price: price(pricing[m]?["input"]).flatMap { i in price(pricing[m]?["output"]).map { i + $0 } }, runtimes: ["hermes"])
                }
            })
        }
        let roles = Set(lists[1].map(\.id))
        return (lists[0].filter { roles.contains($0.id) }, primary)
    }

    // MARK: Role runs (secretary, stronger review, extraction)

    /// "provider/model" → (provider, model); the model id may itself contain "/".
    static func split(_ model: String) throws -> (provider: String, model: String) {
        guard let cut = model.firstIndex(of: "/"), cut != model.startIndex, model.index(after: cut) != model.endIndex
        else { throw ProjectError.blocked(model.isEmpty ? "No model is set for this role; choose one in Settings › Advanced." : "Hermes needs models as provider/model; \(model) has no provider.") }
        return (String(model[..<cut]), String(model[model.index(after: cut)...]))
    }
    /// Fails closed unless the run was served by exactly the requested pair (H6.1: a fallback model is a mismatch).
    /// Providers compare as Hermes resolves them: lowercased, and `openai` served as `custom` (runtime_provider.py,
    /// runtime_provider_custom.py); the request side is the run's `runtime.requested` when present.
    static func verify(_ run: HermesRun, provider: String? = nil, model: String? = nil) throws {
        let resolved = { (p: String?) in p.map { $0.lowercased() == "openai" ? "custom" : $0.lowercased() } }
        let wanted = (resolved(run.requestedProvider ?? provider), run.requestedModel ?? model)
        guard wanted.0 != nil, resolved(run.provider) == wanted.0, run.model == wanted.1, provider.map({ resolved($0) == wanted.0 }) ?? true, model.map({ $0 == wanted.1 }) ?? true else {
            throw HarnessError.modelMismatch("Hermes served this run with \(run.provider ?? "?")/\(run.model ?? "?") instead of \(wanted.0 ?? "?")/\(wanted.1 ?? "?"); its output was not used.")
        }
    }
    /// Hermes-only role framing (transport, not product policy): Hermes always prepends its own core system prompt.
    static let roleRules = "You are one of Yorozu's internal roles, run once with no memory of earlier runs. Use no tools. Reply with exactly what the request asks for, nothing else."
    static let policyHeading = "\n\nRouting policy:\n"
    /// What a role run adds on top of the shared prompt: the framing and the policy heading.
    static let roleOverhead = roleRules.utf8.count + policyHeading.utf8.count

    /// A fresh one-shot run in `yorozu-roles` (no session id: Hermes makes a new session per run).
    func role(_ input: String, instructions: String, model: String, source: String?) async throws -> String {
        // The shared cap covers instructions plus input; `rawPromptCap` leaves room for the framing.
        guard input.utf8.count + instructions.utf8.count <= rawPromptCap + Self.roleOverhead else { throw ProjectError.invalid("Model input exceeds bounded context.") }
        let (provider, name) = try Self.split(model), p = Self.rolesProfile
        let run: String
        do { run = try await submit(p, body: ["input": input, "instructions": instructions, "provider": provider, "model": name], key: "yorozu-role-" + identifier(), source: source) }
        catch let r as Refused { throw r.error }
        let client = client
        let end: HermesRun
        do {
            end = try await withThrowingTaskGroup(of: HermesRun?.self) { g in
                g.addTask { try await client.follow(p, run: run) { _ in } }
                g.addTask { try await Task.sleep(for: .seconds(Self.roleTimeout)); return nil }
                defer { g.cancelAll() }
                guard let first = try await g.next(), let value = first else { throw ProjectError.uncertain("Hermes did not finish this role run within \(Int(Self.roleTimeout)) s; it was stopped.") }
                return value
            }
        } catch { _ = try? await client.call(p, "POST", "/v1/runs/\(run)/stop"); throw error }
        guard end.status == "completed" else { throw try failure(end, input: nil) }
        try Self.verify(end, provider: provider, model: name)
        guard let text = end.output, !text.isEmpty else { throw ProjectError.invalid("Hermes returned an empty answer; withheld.") }
        return text
    }

    public func route(_ input: RoutingInput, stronger: Bool) async throws -> Decision {
        // The policy goes in as instructions; the shared prompt keeps its contract and context data as the input.
        var slim = input; slim.policy = "(the routing policy is in your system instructions)"
        let prompt = Prompts.routingPrompt(slim, stronger: stronger)
        let s = settings()
        let reply = try await role(prompt, instructions: Self.roleRules + Self.policyHeading + input.policy, model: stronger ? s.reviewModel : s.secretaryModel, source: input.sourceMessageID)
        return try JSONDecoder().decode(Decision.self, from: Data(reply.utf8))
    }

    public func extract(_ message: Message, existing: [MemoryHit], context: String?) async throws -> [MemoryProposal] {
        if sensitive(message.body) { return [] }
        let prompt = try Prompts.extractionPrompt(message, existing: existing, context: context, cap: rawPromptCap)
        let reply = try await role(prompt, instructions: Self.roleRules, model: settings().extractionModel, source: message.id)
        do { return try JSONDecoder().decode([MemoryProposal].self, from: Data(reply.utf8)) }
        catch { throw ProjectError.invalid("Extraction reply is not a valid proposal array (\(reply.utf8.count) bytes): \(utf8Prefix(String(describing: error), bytes: 300))") }
    }

    // MARK: Workers

    /// `POST /v1/runs` with the Yorozu run id as `Idempotency-Key`. A dropped connection is retried with the identical
    /// body, which Hermes answers with the original run (202, `Idempotency-Replayed`). A request receipt (correlation
    /// only: request id, session, source message) is saved before the first attempt and again with how it ended.
    /// `stamp` records the run id once the receipt is saved, before anything is sent. Whatever fails before a request
    /// left (the receipt, the Keychain key) is `Refused`: nothing ran.
    func submit(_ profile: String, body: [String:Any], key: String, source: String?, stamp: (() async throws -> Void)? = nil) async throws -> String {
        var receipt = RequestReceipt(requestID: key, harness: id, sessionKey: body["session_id"] as? String, sourceMessageID: source, rawModelRun: body["session_id"] == nil, state: "submitted")
        do { try await audit?(receipt) } catch { throw Refused(error: error) } // Durable before dispatch; fail closed if saving correlation fails.
        let settle = { [audit] (state: String) async in receipt.state = state; receipt.created = Date().timeIntervalSince1970; try? await audit?(receipt) }
        do { try await stamp?() } catch { await settle("not-sent"); throw error }
        for attempt in 1...3 {
            do {
                let (code, json) = try await client.call(profile, "POST", "/v1/runs", body: body, headers: ["Idempotency-Key": key])
                guard [200, 202].contains(code), let run = json["run_id"] as? String, !run.isEmpty, !run.contains(":") else {
                    await settle("rejected"); throw Refused(error: HermesClient.failure(code, json, profile: profile, doing: "start the run"))
                }
                await settle("admitted"); return run
            } catch let e as Refused { throw e
            } catch let e as HermesClient.Unreachable {
                if attempt == 3 { await settle("uncertain"); throw ProjectError.uncertain(e.localizedDescription + " The run may have started; reconcile before retry. Request ID: " + key) }
                try await Task.sleep(for: .seconds(2))
            } catch {
                // A typed error comes before any request left (e.g. no API key in the Keychain): nothing was sent, unless
                // an earlier attempt may have reached Hermes.
                let notSent = attempt == 1 && (error is ProjectError || error is HarnessError)
                await settle(notSent ? "not-sent" : "uncertain"); throw notSent ? Refused(error: error) : error
            }
        }
        throw ProjectError.uncertain("unreachable")
    }
    /// Hermes answered and did not admit the run: nothing ran.
    struct Refused: Error { var error: Error }

    /// Create the session once per app run (and re-lock it when its model changes): client-chosen id, topic label as
    /// title, model lock. An existing session gets the lock through `POST /api/sessions/{id}/model`.
    func ensureSession(_ session: String, title: String, model: String) async throws {
        guard await state.locked[session] != model else { return }
        let (provider, name) = try Self.split(model), p = Self.workerProfile
        // Hermes 0.21.6 keeps only its own source names and stores this one as "api_server".
        var body: [String:Any] = ["id": session, "title": title, "source": "yorozu", "provider": provider, "model": name, "require_model_lock": true]
        var (code, json) = try await call(p, "POST", "/api/sessions", body)
        if code == 400, HermesClient.errorCode(json) == "invalid_title" { body["title"] = nil; (code, json) = try await call(p, "POST", "/api/sessions", body) }
        if code == 409, HermesClient.errorCode(json) == "session_exists" { (code, json) = try await call(p, "POST", "/api/sessions/\(session)/model", ["provider": provider, "model": name]); if code == 200 { code = 201 } }
        guard code == 201 else { throw HermesClient.failure(code, json, profile: p, doing: "prepare session \(session)") }
        await state.lock(session, model)
    }
    private func call(_ p: String, _ method: String, _ path: String, _ body: [String:Any]? = nil) async throws -> (status: Int, json: [String:Any]) {
        do { return try await client.call(p, method, path, body: body) }
        catch let e as HermesClient.Unreachable { throw ProjectError.uncertain(e.localizedDescription) }
    }
    /// The session's live id: compaction rotates a session to a continuation that Hermes maps back to the same id.
    func effective(_ session: String) async -> String? {
        try? await client.call(Self.workerProfile, "GET", "/api/sessions/\(session)/messages?limit=1").json["session_id"] as? String
    }

    static func controllerKey(_ runID: String, _ server: String) -> String { "hermes:\(runID):\(server)" }
    /// The server run id of `work`'s current run: from its controller key when that names this run id, else from this app run.
    func server(_ work: Work) async -> String? {
        guard let run = work.runID else { return nil }
        if let key = work.controllerKey, key.hasPrefix("hermes:\(run):") { return String(key.dropFirst("hermes:\(run):".count)) }
        return await state.servers[run]
    }

    public func run(_ input: WorkerInput, update: @escaping @Sendable (StreamUpdate) async throws -> Void, memory: @escaping @Sendable (MemoryCall) async throws -> String) async throws -> WorkerOutput {
        let s = settings()
        if let executor = input.work.executor {
            guard executors.contains(where: { $0.id == executor }) else { throw HarnessError.notReady("Hermes offers only the Hermes coding executor; \(executor) is not available.") }
            return try await code(input, settings: s, update: update)
        }
        let session = "yorozu-" + input.topic.id
        try await ensureSession(session, title: input.topic.label, model: s.workerModel)
        // The contract goes in as instructions on every run, so only the wire (or follow-up) is input.
        let instructions = Prompts.thinkingContract(s, topic: input.topic.id, cuaSession: "yorozu-" + identifier().prefix(8)) + " " + Self.workerRules
        // Attached files go by path only: Hermes takes no image input from Yorozu yet.
        var wire = try Prompts.workerMessage(input, root: s.filesRoot)
        for i in 0...Prompts.memoryOperations {
            let end = try await step(input, session: session, runID: "yorozu-run-" + identifier(), text: wire, instructions: instructions, model: s.workerModel, update: update)
            switch try Prompts.workerReply(end.output ?? "", step: i) {
            case .final(let output): return Self.applied(output, pendingSteer: end.pendingSteer, dispatched: input.work.revision)
            case .memory(let call): wire = try await Prompts.memoryStep(call, eventID: input.work.id + ":" + end.id + ":memory", task: input.work.id, update: update, memory: memory)
            }
        }
        throw ProjectError.invalid("Worker invocation ended without an answer.")
    }
    /// Hermes-only worker note: its own memory layer is off in `yorozu-worker`, and Yorozu's memory is the one to use.
    static let workerRules = "Hermes's own memory, skills and scheduled jobs are not yours to use: keep knowledge in Yorozu's memory through memoryCall."

    /// One run in `session`: size guard, stamp, submit, record the server run, stream progress, then check how it ended,
    /// which model served it and whether the session rotated.
    func step(_ input: WorkerInput, session: String, runID: String, text: String, instructions: String, model: String, update: @escaping @Sendable (StreamUpdate) async throws -> Void) async throws -> HermesRun {
        // Checked before the run id is stamped: an oversized step never dispatches.
        let size = text.utf8.count + instructions.utf8.count
        guard size <= workerGuard else { throw ProjectError.overflow("This step's input is too large to send (\(size) bytes, limit \(workerGuard)).") }
        let (provider, name) = try Self.split(model), p = Self.workerProfile, task = input.work.id
        if await state.effective[session] == nil, let now = await effective(session) { await state.setEffective(session, now) }
        let server: String
        do {
            server = try await submit(p, body: ["session_id": session, "input": text, "instructions": instructions, "provider": provider, "model": name], key: runID, source: input.work.messageID) {
                try await update(.handle(RunHandle(sessionKey: session, controllerKey: "", runID: runID)))
            }
        }
        catch let r as Refused {
            // Never admitted: say so durably, so reconcile reports it stopped and the task stays retryable.
            try? await update(.handle(RunHandle(sessionKey: session, controllerKey: Self.controllerKey(runID, "refused"), runID: runID)))
            throw r.error
        }
        await state.setServer(runID, server)
        do { try await update(.handle(RunHandle(sessionKey: session, controllerKey: Self.controllerKey(runID, server), runID: runID))) }
        catch { _ = await stop(p, server); throw error } // Stopped meanwhile: the run must not go on unwatched.
        let client = client
        let end = try await client.follow(p, run: server) { e in
            if e["event"] as? String == "approval.request" {
                // Open question 6: approvals are off in yorozu-worker, so one arriving is unexpected; deny, stop, fail.
                _ = try? await client.call(p, "POST", "/v1/runs/\(server)/approval", body: ["choice": "deny", "all": true])
                _ = try? await client.call(p, "POST", "/v1/runs/\(server)/stop")
                throw HarnessError.approvalRequested("Hermes asked to approve a step, but approvals are off for Yorozu's workers. Yorozu denied it and stopped the task; check the yorozu-worker profile's approvals setting, then say retry.")
            }
            if let event = Self.event(e, task: task, run: server) { try? await Prompts.emitProgress(event, update: update) }
        }
        guard end.status == "completed" else { throw try failure(end, input: input, update: update) }
        try Self.verify(end, provider: provider, model: name)
        if let before = await state.effective[session], let now = await effective(session), now != before {
            await state.setEffective(session, now)
            try? await update(.event(WorkerEvent(id: task + ":" + server + ":compaction", taskID: task, kind: "compaction", body: "Hermes compacted this topic's session.", created: Date().timeIntervalSince1970)))
        }
        return end
    }

    /// A run that did not complete, as a plain error. Context overflow (and a failed compaction, also posted to the
    /// main timeline) would fail the same way again.
    func failure(_ end: HermesRun, input: WorkerInput?, update: (@Sendable (StreamUpdate) async throws -> Void)? = nil) throws -> Error {
        let error = end.error.map { sensitive($0) ? "" : ": " + utf8Prefix($0, bytes: 300) } ?? ""
        switch end.status {
        case "cancelled": return ProjectError.invalid("The Hermes run was stopped.")
        case "interrupted": return HarnessError.interrupted("Hermes restarted while this run was going (run interrupted). Say retry to run it again.")
        default:
            let text = end.error ?? ""
            if text.range(of: "compress|compaction", options: [.regularExpression, .caseInsensitive]) != nil, let input, let update {
                Task { try? await update(.notice("Couldn't compact the session of topic “\(input.topic.label)”\(error)")) }
                return ProjectError.overflow("This topic's Hermes session is too long and could not be compacted. Start a new topic for this request.")
            }
            if text.range(of: "context.*overflow|context window.*(too (large|long)|exceed|over|limit|max)|context.?length|prompt.*too (large|long)|maximum context|request_too_large|too many tokens|token limit exceeded", options: [.regularExpression, .caseInsensitive]) != nil {
                return ProjectError.overflow("This topic's Hermes session ran out of context. Start a new topic for this request.")
            }
            return ProjectError.invalid("Hermes run failed\(error).")
        }
    }

    /// Steer text Hermes queued but never delivered (`pending_steer`) lowers the applied revision below the first
    /// undelivered amendment, so `Store.finish` runs it as a follow-up turn.
    static func applied(_ output: WorkerOutput, pendingSteer: String?, dispatched: Int) -> WorkerOutput {
        guard let pending = pendingSteer, !pending.isEmpty else { return output }
        let revisions = pending.matches(of: #/"revision"\s*:\s*(\d+)/#).compactMap { Int($0.1) }
        var o = output; o.appliedRevision = min(o.appliedRevision, revisions.min().map { $0 - 1 } ?? dispatched); return o
    }

    /// Public progress from one run event; never tool arguments (the terminal command is the one exception: its
    /// redacted preview is the command row), reasoning or the worker contract's JSON.
    static func event(_ e: [String:Any], task: String, run: String) -> WorkerEvent? {
        guard let name = e["event"] as? String, let seq = e["seq"] as? Int else { return nil }
        var kind = "lifecycle", body: String?
        switch name {
        case "tool.started":
            guard let tool = e["tool"] as? String, tool.count <= 100 else { return nil }
            if tool == "terminal", let preview = e["preview"] as? String, !preview.isEmpty { kind = "command"; body = "$ " + String(preview.prefix(2000)) }
            else { kind = "tool"; body = toolRow(tool.hasPrefix("mcp__") ? String(tool.dropFirst(5)) : tool, args: nil) } // MCP tools are mcp__<server>__<tool>
        case "tool.completed":
            guard let preview = e["preview"] as? String, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            kind = e["error"] as? Bool == true ? "error" : "output"; body = preview // ≤ 500 chars, redacted by Hermes
        case "message.interim":
            guard let text = e["text"] as? String else { return nil }
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String:Any]
            guard object?["memoryCall"] == nil, object?["appliedRevision"] == nil else { return nil }
            kind = "message"; body = text
        case "subagent.start": body = "Subagent started"
        case "subagent.complete": body = "Subagent finished" + ((e["status"] as? String).map { ": " + $0.prefix(40) } ?? "")
        case _ where name.hasPrefix("run."): body = "Worker lifecycle: " + name.dropFirst(4)
        default: return nil // message.delta, reasoning.available, replay.truncated, approval.*
        }
        guard let text = body, !sensitive(text) else { return nil }
        return WorkerEvent(id: task + ":" + run + ":event:\(seq)", taskID: task, kind: kind, body: text, created: e["timestamp"] as? Double ?? Date().timeIntervalSince1970)
    }

    // MARK: Control

    public func steer(_ work: Work, topic: Topic, amendment: Amendment) async throws -> Bool {
        guard let server = await server(work), server != "refused" else { return false }
        // 200 means queued for the next tool boundary; 409 (not running, or not accepted) leaves it for a follow-up.
        let (code, _) = try await call(Self.workerProfile, "POST", "/v1/runs/\(server)/steer", ["input": try encoded(amendment)])
        return code == 200 || code == 202
    }

    public func cancel(_ work: Work, topic: Topic) async throws -> Bool {
        // Never dispatched, or another harness's run (a harness switch): nothing here to stop.
        guard work.runID?.hasPrefix("yorozu-") ?? false else { return true }
        guard let server = await server(work) else { return Self.forgotten(work) } // Admission unknown (open question 7).
        return server == "refused" ? true : await stop(Self.workerProfile, server)
    }
    /// A run whose server id was never recorded is taken as gone once Hermes has forgotten its idempotency key (24 h),
    /// counted from when the work was created (no later than its run's stamp).
    static func forgotten(_ work: Work) -> Bool { Date().timeIntervalSince1970 - work.created > 86400 }
    /// `/stop`, then poll until the run settles (about 30 s); true once it is terminal or Hermes no longer knows it.
    func stop(_ p: String, _ server: String) async -> Bool {
        _ = try? await client.call(p, "POST", "/v1/runs/\(server)/stop")
        for _ in 0..<30 {
            do { if try await client.status(p, server)?.terminal != false { return true } } catch {}
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    public func reconcile(_ work: Work, topic: Topic) async throws -> RunStatus {
        guard let id = work.runID else { return .unknown }
        guard id.hasPrefix("yorozu-") else { return .stopped } // Another harness's run: not reachable from here.
        guard let server = await server(work) else { return Self.forgotten(work) ? .stopped : .unknown }
        if server == "refused" { return .stopped }
        guard let run = try await client.status(Self.workerProfile, server) else { return .unknown }
        switch run.status {
        case "completed":
            guard (try? Self.verify(run)) != nil, let text = run.output, !text.isEmpty else { return .stopped }
            if work.executor != nil { return .completed(Self.applied(Prompts.coded(text, revision: work.revision), pendingSteer: run.pendingSteer, dispatched: work.revision)) }
            guard case .final(let output)? = try? Prompts.workerReply(text, step: 0) else { return .stopped }
            return .completed(Self.applied(output, pendingSteer: run.pendingSteer, dispatched: work.revision))
        case "cancelled", "interrupted", "failed": return .stopped
        default: return .running // queued, running, stopping, waiting_for_approval
        }
    }

    // MARK: Coding (open question 2)

    func code(_ input: WorkerInput, settings s: HarnessSettings, update: @escaping @Sendable (StreamUpdate) async throws -> Void) async throws -> WorkerOutput {
        guard let repo = s.devRepo else { throw ProjectError.blocked("No repository is set for coding work. Set a repository in Settings › Advanced.") }
        let s = try s.resolvingBase(repo), executor = executors[0], session = "yorozu-\(input.topic.id)-\(executor.id)"
        let model = s.codingModels[executor.id].flatMap { $0.isEmpty ? nil : $0 } ?? s.workerModel
        try await ensureSession(session, title: input.topic.label + " · coding", model: model)
        // No per-session working folder under Hermes (open question 2): the worker makes and reuses its own worktree.
        let slug = input.topic.label.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }
            .joined().split(separator: "-").joined(separator: "-").prefix(32)
        let name = (slug.isEmpty ? "" : slug + "-") + input.topic.id.prefix(6)
        let tree = (repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + "-yorozu-" + name).path, "yorozu/" + name)
        let contract = Prompts.codingContract(executor: executor.name, repo: repo, settings: s, topic: input.topic.id, cuaSession: "yorozu-" + identifier().prefix(8), worktree: tree)
        let runID = "yorozu-code-" + identifier()
        let end = try await step(input, session: session, runID: runID, text: Prompts.codingTask(input, runID: runID, root: s.filesRoot), instructions: contract, model: model, update: update)
        // No diffstat under Hermes (open question 8).
        let text = end.output.flatMap { $0.isEmpty ? nil : $0 } ?? executor.name + " finished without a summary."
        // Relative returned paths resolve against its worktree.
        return Self.applied(Prompts.coded(text, revision: input.work.revision, base: URL(fileURLWithPath: tree.0)), pendingSteer: end.pendingSteer, dispatched: input.work.revision)
    }
}

/// Per app run: sessions created and locked to a model, each session's live id, and server run ids by Yorozu run id.
actor HermesState {
    private(set) var locked: [String:String] = [:], effective: [String:String] = [:], servers: [String:String] = [:]
    func lock(_ session: String, _ model: String) { locked[session] = model }
    func setEffective(_ session: String, _ id: String) { effective[session] = id }
    func setServer(_ run: String, _ server: String) { servers[run] = server }
}
