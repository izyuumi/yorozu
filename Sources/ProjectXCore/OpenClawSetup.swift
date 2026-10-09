import Foundation
import CryptoKit

/// OpenClaw's setup seam (#317): detection, read-only checks of Yorozu's own entry, role models and provider auth, and the
/// assisted write. Every Gateway call goes through `GatewayRPC` (loopback pin, attribution guard). The write is one
/// `config.patch` of Yorozu's own keys only, made only on an explicit user action (`apply`).
public struct OpenClawSetup: HarnessSetup {
    public var kind: Config.HarnessKind { .openclaw }
    public var title: String { "OpenClaw" }
    public var steps: [String] { ["harness","gateway","models"] }
    public var agent: String, rpc: GatewayRPC
    public init(agent: String, rpc: GatewayRPC) { self.agent = agent; self.rpc = rpc }

    /// `tool` on the launch PATH plus `/opt/homebrew/bin` and `/usr/local/bin`, the rule `GatewayRPC` launches `openclaw` by.
    public static func which(_ tool: String, extra: [String] = []) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init) + ["/opt/homebrew/bin","/usr/local/bin"] + extra
        return dirs.map { ($0 as NSString).expandingTildeInPath + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// False in a process started from an OpenClaw agent's exec shell (`GatewayRPC.enforceAttribution`): setup then leaves
    /// Gateway steps to the app and never works around the markers.
    public static var gatewayAllowed: Bool { (try? GatewayRPC.enforceAttribution(ProcessInfo.processInfo.environment)) != nil }
    /// Setup and readiness probes wait at most this long on the CLI transport (ms).
    static let probe = 30_000

    public var installed: Bool { Self.which("openclaw") != nil && Self.which("node") != nil }
    public func detect() async -> HarnessDetection {
        var d = HarnessDetection(kind: kind,title: title)
        var health: Error? // nil once `health` answered
        func probe() async { do { _ = try await rpc.call("health",[:],timeout: Self.probe); health = nil; d.reachable = true } catch { health = error; d.reachable = false } }
        let install = Readiness.Item.Fix.open(title: String(localized: "How to install OpenClaw"),url: URL(string: "https://github.com/openclaw/openclaw")!)
        if let openclaw = Self.which("openclaw"), let node = Self.which("node") {
            // Through node itself: Finder's PATH may lack the folder the script's `env node` needs.
            let version = await Integration.Check(title: "OpenClaw version",kind: .command(executables: [node],args: [openclaw,"--version"],readOnly: true)).run(timeout: 15)
            d.version = version.detail.firstMatch(of: #/\d{4}\.\d+\.\d+/#).map { String($0.0) }
            d.items = [Readiness.Item(id: "openclaw.installed",title: String(localized: "OpenClaw is installed"),detail: openclaw + (d.version.map { " " + $0 } ?? ""),severity: .ok)]
            guard Self.gatewayAllowed else { d.installed = true; d.items.append(Self.inApp); return d }
            await probe()
        } else {
            let detail = "Not found on PATH, /opt/homebrew/bin or /usr/local/bin: " + [Self.which("openclaw") == nil ? "openclaw" : nil, Self.which("node") == nil ? "node" : nil].compactMap { $0 }.joined(separator: ", ")
            // A Gateway that answers anyway (the native client) still serves Yorozu; only the CLI's admin calls are missing.
            if Self.gatewayAllowed { await probe() }
            guard d.reachable == true else {
                d.reachable = nil
                d.items = [Readiness.Item(id: "openclaw.installed",title: String(localized: "OpenClaw or Node.js isn't installed"),detail: detail,severity: .blocking,fix: install)]
                return d
            }
            d.items = [Readiness.Item(id: "openclaw.installed",title: String(localized: "OpenClaw's command line isn't found; setup writes and some features are unavailable"),detail: detail,severity: .warning,fix: install)]
        }
        d.installed = true
        if let health {
            d.items.append(Readiness.Item(id: "openclaw.gateway",title: PlainError.describe(health)?.title ?? String(localized: "The OpenClaw Gateway isn't answering"),detail: health.localizedDescription,severity: .warning,fix: .copy(title: String(localized: "Copy start command"),command: "openclaw gateway run")))
            return d
        }
        d.items.append(Readiness.Item(id: "openclaw.gateway",title: String(localized: "The OpenClaw Gateway is running"),severity: .ok))
        // Workers never run on the user's personal agent (the default one).
        let config = (try? await rpc.call("config.get",[:],timeout: Self.probe))?["config"] as? [String:Any]
        if Self.personal(agent,config: config) { d.items.append(Readiness.Item(id: "openclaw.personal",title: Self.personalAgent,detail: "[harness] agent = \(agent)",severity: .blocking,fix: .step("harness"))) }
        return d
    }
    static let inApp = Readiness.Item(id: "openclaw.gateway",title: String(localized: "Gateway checks are left to the Yorozu app"),detail: "This process was started from an OpenClaw agent's shell, so it makes no Gateway calls. Open Yorozu from Finder and finish setup there.",severity: .warning,fix: .step("harness"))
    public static let personalAgent = String(localized: "Yorozu needs its own OpenClaw agent, not your main one. Set [harness] agent to a dedicated id.")
    /// `agent` is OpenClaw's default agent: id `main`, or an entry marked `default: true` in `config` (a `config.get` answer's).
    public static func personal(_ agent: String, config: [String:Any]?) -> Bool {
        let entries = (config?["agents"] as? [String:Any])?["entries"] as? [String:Any]
        return agent.lowercased() == "main" || (entries?[agent] as? [String:Any])?["default"] as? Bool == true
    }

    /// Read-only: Yorozu's entry, the role models, provider auth, and the assisted write that would fix what a write can.
    /// Calls `config.get`, `models.list` (configured, and all only when a role model is missing) and `models.authStatus`.
    /// Refuses OpenClaw's default agent (`personal`), so `apply` never writes it.
    public func inspect(_ settings: ResolvedSettings, dataRoot: URL) async throws -> OpenClawInspection {
        let snapshot = try await rpc.call("config.get",[:],timeout: Self.probe)
        guard let hash = snapshot["hash"] as? String, let config = snapshot["config"] as? [String:Any] else { throw ProjectError.uncertain("OpenClaw's config could not be read (config.get).") }
        guard !Self.personal(agent,config: config) else { throw ProjectError.blocked(Self.personalAgent) }
        let c = settings.config, agents = config["agents"] as? [String:Any] ?? [:], entries = agents["entries"] as? [String:Any] ?? [:]
        let entry = entries[agent] as? [String:Any], base = "agents.entries.\(agent)"
        var out = OpenClawInspection(), patch: [String:Any] = [:], changes: [OpenClawPlan.Change] = [], replace: [String] = []
        func change(_ key: String, _ value: Any?, old: Any?, path: String? = nil) {
            let path = path ?? base + "." + key
            changes.append(.init(path: path,old: old.map(json),new: value.map(json)))
            if let old { replace += OpenClawHarness.arrayPaths(old,path) }
        }

        // Yorozu's own entry in today's shape (docs/setup.md); nothing else in it is inspected.
        let workspace = Self.workspace(dataRoot)
        var shape: [String] = []
        if let entry {
            out.entry.append(Readiness.Item(id: "openclaw.agent",title: String(localized: "Yorozu's agent \(agent) is set up in OpenClaw"),severity: .ok))
            if Self.normalized(entry["workspace"] as? String) != workspace.standardizedFileURL.path { shape.append("workspace") }
            if Self.primary(entry["model"]) == nil, Self.primary(c.models.worker) ?? Self.primary((agents["defaults"] as? [String:Any])?["model"]) != nil { shape.append("model") }
            if entry["contextInjection"] as? String != "never" { shape.append("contextInjection") }
            if (entry["skills"] as? [Any])?.isEmpty != true { shape.append("skills") }
            if ((entry["subagents"] as? [String:Any])?["allowAgents"] as? [Any])?.isEmpty != true { shape.append("subagents") }
            if entry["tools"] != nil { shape.append("tools") }
        } else {
            out.entry.append(Readiness.Item(id: "openclaw.agent",title: String(localized: "Yorozu's agent isn't set up in OpenClaw"),detail: "agents.entries.\(agent) is missing.",severity: .warning,fix: .step("harness")))
            // A second entry is valid only in an explicit roster; Yorozu never writes agents.ownership, so OpenClaw adds it.
            let explicit = agents["ownership"] as? String == "explicit" || entries.values.contains { ($0 as? [String:Any])?["default"] as? Bool == true }
            if !explicit || entries.isEmpty {
                out.blocked = Readiness.Item(id: "openclaw.roster",title: String(localized: "Add Yorozu's agent with OpenClaw first"),detail: "OpenClaw's agent list isn't in explicit mode (agents.ownership), and Yorozu writes only its own entry. Add the agent with OpenClaw, then run setup again.",severity: .warning,
                                             fix: .copy(title: String(localized: "Copy command"),command: "openclaw agents add \(agent) --non-interactive --workspace \(Self.quoted(workspace.path))"))
            } else { shape = ["workspace","model","contextInjection","skills","subagents"] }
        }
        for key in shape {
            switch key {
            case "workspace": patch[key] = workspace.path; change(key,workspace.path,old: entry?[key])
            case "model":
                guard let primary = Self.primary(c.models.worker) ?? Self.primary((agents["defaults"] as? [String:Any])?["model"]) else { continue }
                patch[key] = ["primary": primary]; change(key,primary,old: Self.primary(entry?[key]),path: base + ".model.primary")
            case "contextInjection": patch[key] = "never"; change(key,"never",old: entry?[key])
            case "skills": patch[key] = [String](); change(key,[String](),old: entry?[key])
            case "subagents":
                let old = (entry?["subagents"] as? [String:Any])?["allowAgents"]
                patch[key] = ["allowAgents": [String]()]; change(key,[String](),old: old,path: base + ".subagents.allowAgents")
            default: patch[key] = NSNull(); change(key,nil,old: entry?[key])
            }
        }
        if entry != nil, !changes.isEmpty {
            out.entry.append(Readiness.Item(id: "openclaw.agent.shape",title: String(localized: "Yorozu's agent \(agent) differs from what Yorozu expects"),detail: changes.map(\.line).joined(separator: "\n"),severity: .warning,fix: .step("harness")))
        } else if entry != nil {
            out.entry.append(Readiness.Item(id: "openclaw.agent.shape",title: String(localized: "Yorozu's agent has the expected settings"),severity: .ok))
        }
        // Role models: usable when models.list (configured, so the agent's model policy applies) lists them available.
        var used = Set<String>()
        if entry != nil {
            do {
                let rows = try await rpc.call("models.list",["agentId":agent,"view":"configured","includeDetails":true],timeout: Self.probe)["models"] as? [[String:Any]] ?? []
                let meta = OpenClawHarness.models(rows,config: config)
                let m = settings.models(meta.allowed,primary: meta.primary)
                let roles = [("Secretary",String(localized: "Secretary"),m.secretary),("Memory extraction",String(localized: "Memory extraction"),m.extraction),("Worker",String(localized: "Worker"),m.worker),("Review",String(localized: "Review"),m.review)]
                let byID = Dictionary(rows.map { ("\($0["provider"] as? String ?? "")/\($0["id"] as? String ?? "")",$0) }) { a,_ in a }
                var missing: [String] = []
                used = Set(roles.compactMap { $0.2.id?.split(separator: "/").first.map(String.init) })
                for (role,name,choice) in roles {
                    guard let id = choice.id else { out.models.append(Readiness.Item(id: "openclaw.model.\(role)",title: String(localized: "No model is set for \(name)"),detail: choice.reason,severity: .warning,fix: .step("models"))); continue }
                    if let row = byID[id] {
                        let reason = row["unavailableReason"] as? String
                        out.models.append(row["available"] as? Bool == false
                            ? Readiness.Item(id: "openclaw.model.\(role)",title: String(localized: "\(name): \(id) can't be used right now"),detail: reason ?? "unavailable",severity: .warning,fix: reason == "cooldown" ? nil : .copy(title: String(localized: "Copy sign-in command"),command: "openclaw models auth login --agent \(agent) --provider \(id.split(separator: "/").first ?? "")"))
                            : Readiness.Item(id: "openclaw.model.\(role)",title: "\(name): \(id)",severity: .ok))
                    } else { missing.append(id) }
                }
                missing = Array(Set(missing)).sorted()
                if !missing.isEmpty {
                    // Known to OpenClaw but outside the agent's policy: the assisted write adds them to Yorozu's own allow list.
                    let all = Set((try await rpc.call("models.list",["agentId":agent,"view":"all"],timeout: Self.probe)["models"] as? [[String:Any]] ?? []).map { "\($0["provider"] as? String ?? "")/\($0["id"] as? String ?? "")" })
                    let policy = ((entry?["modelPolicy"] as? [String:Any])?["allow"] ?? (((agents["defaults"] as? [String:Any])?["modelPolicy"] as? [String:Any])?["allow"])) as? [String] ?? []
                    let allowable = policy.isEmpty ? [] : missing.filter(all.contains) // an empty policy allows any model: a list would narrow it
                    for id in missing {
                        out.models.append(Readiness.Item(id: "openclaw.model.\(id)",title: String(localized: "OpenClaw doesn't allow \(id) for Yorozu"),detail: all.contains(id) ? "Not in agent \(agent)'s model policy." : "OpenClaw doesn't list \(id).",severity: .warning,fix: .step("models")))
                    }
                    if !allowable.isEmpty {
                        // Seeded from the policy in force (the entry's, else the defaults'), since an entry's own list replaces the defaults.
                        let old = (entry?["modelPolicy"] as? [String:Any])?["allow"], next = policy + allowable.filter { !policy.contains($0) }
                        patch["modelPolicy"] = ["allow": next]; change("modelPolicy",next,old: old,path: base + ".modelPolicy.allow")
                    }
                }
            } catch {
                out.models.append(Readiness.Item(id: "openclaw.models",title: PlainError.describe(error)?.title ?? String(localized: "OpenClaw's models couldn't be read"),detail: error.localizedDescription,severity: .warning,fix: .step("models")))
            }
            // Provider auth for the role models' providers: the provider and its state only.
            if let providers = try? await rpc.call("models.authStatus",["agentId":agent],timeout: Self.probe)["providers"] as? [[String:Any]] {
                for p in providers {
                    guard let id = p["provider"] as? String, used.contains(id) else { continue }
                    let name = p["displayName"] as? String ?? id, status = p["status"] as? String ?? "unknown", fine = ["ok","static"].contains(status)
                    out.auth.append(Readiness.Item(id: "openclaw.auth.\(id)",title: fine ? String(localized: "\(name): signed in") : status == "expiring" ? String(localized: "\(name): sign-in expires soon") : status == "expired" ? String(localized: "\(name): sign-in expired") : String(localized: "\(name): not signed in"),detail: "\(id): \(status)",severity: fine ? .ok : .warning,
                                                   fix: fine ? nil : .copy(title: String(localized: "Copy sign-in command"),command: "openclaw models auth login --agent \(agent) --provider \(id)")))
                }
            }
        } else {
            out.models.append(Readiness.Item(id: "openclaw.models",title: String(localized: "Models are checked once Yorozu's agent is set up"),severity: .warning,fix: .step("harness")))
        }

        // Yorozu's MCP servers, through the mirror's own patch.
        let configured = (config["mcp"] as? [String:Any])?["servers"] as? [String:Any] ?? [:]
        let (mcp,mcpReplace) = OpenClawHarness.mcpPatch(c.effectiveMCPServers,configured: configured)
        for key in mcp.keys.sorted() { changes.append(.init(path: "mcp.servers." + key,old: configured[key].map(json),new: mcp[key] is NSNull ? nil : mcp[key].map(json))) }
        replace += mcpReplace
        // After every change: any change to an existing entry (its shape or its allow list) is shown and confirmed first.
        let confirm = entry != nil && changes.contains { $0.path.hasPrefix(base + ".") }

        var body: [String:Any] = [:]
        if !patch.isEmpty { body["agents"] = ["entries": [agent: patch]] }
        if !mcp.isEmpty { body["mcp"] = ["servers": mcp] }
        out.plan = OpenClawPlan(changes: changes,needsConfirmation: confirm,raw: body.isEmpty ? "" : json(body),replacePaths: Array(Set(replace)).sorted(),baseHash: hash,
                                workspace: patch["workspace"] != nil ? workspace : nil)
        return out
    }

    /// The assisted write, on an explicit user action: re-inspects, refuses if the plan changed since the user saw it or
    /// needs a confirmation not given, then sends one `config.patch` with `baseHash`, `replacePaths` and no `note` (a note
    /// leaves a restart sentinel that wakes the owner's main agent). A plan with nothing to change writes nothing.
    public func apply(_ plan: OpenClawPlan, settings: ResolvedSettings, dataRoot: URL, confirmed: Bool) async throws {
        let fresh = try await inspect(settings,dataRoot: dataRoot).plan
        guard fresh.changes == plan.changes else { throw ProjectError.conflict("OpenClaw's config changed since it was checked. Check again and review the changes.") }
        guard !fresh.changes.isEmpty else { return }
        guard !fresh.needsConfirmation || confirmed else { throw ProjectError.blocked("Yorozu's agent entry in OpenClaw already exists and differs. Review the changes and confirm them first.") }
        if let folder = fresh.workspace, folder == Self.workspace(dataRoot) { try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700]) }
        let patched = try await rpc.call("config.patch",["raw":fresh.raw,"baseHash":fresh.baseHash,"replacePaths":fresh.replacePaths])
        guard patched["ok"] as? Bool == true else { throw ProjectError.uncertain("OpenClaw did not confirm the config update.") }
    }

    /// The agent's workspace: an empty Yorozu-owned folder, where OpenClaw's bootstrap files land. Topic sessions work in
    /// their task folders (`sessions.create` `cwd`, #351).
    public static func workspace(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("openclaw-workspace",isDirectory: true) }
    static func normalized(_ path: String?) -> String? { path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path } }
    /// A model value's primary: "provider/model" or `{primary}`.
    static func primary(_ value: Any?) -> String? {
        let p = value as? String ?? (value as? [String:Any])?["primary"] as? String
        return p?.isEmpty == false ? p : nil
    }
    static func quoted(_ s: String) -> String { s.range(of: #"^[A-Za-z0-9_./~-]+$"#,options: .regularExpression) != nil ? s : "'" + s.replacingOccurrences(of: "'",with: "'\\''") + "'" }
}

/// What `OpenClawSetup.inspect` found, as readiness items, and the assisted write.
public struct OpenClawInspection: Sendable {
    /// Yorozu's entry: present, and in the expected shape.
    public var entry: [Readiness.Item] = []
    /// The role models, each usable or not.
    public var models: [Readiness.Item] = []
    /// Provider auth for the role models' providers.
    public var auth: [Readiness.Item] = []
    /// Why a write can't add the entry (the roster), with the command that does it; nil when a write can.
    public var blocked: Readiness.Item?
    public var plan = OpenClawPlan()
}

/// The assisted OpenClaw write: what changes, for the UI to show, and the patch itself.
public struct OpenClawPlan: Sendable, Equatable {
    /// One changed config path; `old` and `new` are JSON text, nil when absent.
    public struct Change: Sendable, Equatable {
        public var path: String, old: String?, new: String?
        public var line: String { "\(path): \(old ?? "(none)") → \(new ?? "(removed)")" }
    }
    public var changes: [Change] = []
    /// Yorozu's entry already exists and the write changes its shape: show `changes` and ask before applying.
    public var needsConfirmation = false
    public var isEmpty: Bool { changes.isEmpty }
    /// 12 hex digits of SHA-256 over `changes`: the CLI's `plan_digest`, which `apply:<digest>` must name.
    public var digest: String { SHA256.hash(data: Data(changes.map(\.line).joined(separator: "\n").utf8)).prefix(6).map { String(format: "%02x",$0) }.joined() }
    var raw = "", replacePaths: [String] = [], baseHash = ""
    /// The workspace the write sets, created first when it is Yorozu's own folder.
    var workspace: URL?
}

private func json(_ value: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: value,options: [.sortedKeys,.fragmentsAllowed,.withoutEscapingSlashes])).map { String(decoding: $0,as: UTF8.self) } ?? "\(value)"
}
