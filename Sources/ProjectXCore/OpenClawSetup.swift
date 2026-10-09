import Foundation

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
        guard let openclaw = Self.which("openclaw"), let node = Self.which("node") else {
            let missing = [Self.which("openclaw") == nil ? "openclaw" : nil, Self.which("node") == nil ? "node" : nil].compactMap { $0 }
            d.items = [Readiness.Item(id: "openclaw.installed",title: "OpenClaw or Node.js isn't installed",detail: "Not found on PATH, /opt/homebrew/bin or /usr/local/bin: " + missing.joined(separator: ", "),severity: .blocking,fix: .open(title: "How to install OpenClaw",url: URL(string: "https://github.com/openclaw/openclaw")!))]
            return d
        }
        d.installed = true
        // Through node itself: Finder's PATH may lack the folder the script's `env node` needs.
        let version = await Integration.Check(title: "OpenClaw version",kind: .command(executables: [node],args: [openclaw,"--version"],readOnly: true)).run(timeout: 15)
        d.version = version.detail.firstMatch(of: #/\d{4}\.\d+\.\d+/#).map { String($0.0) }
        d.items = [Readiness.Item(id: "openclaw.installed",title: "OpenClaw is installed",detail: openclaw + (d.version.map { " " + $0 } ?? ""),severity: .ok)]
        guard Self.gatewayAllowed else { d.items.append(Self.inApp); return d }
        do {
            _ = try await rpc.call("health",[:],timeout: Self.probe); d.reachable = true
            d.items.append(Readiness.Item(id: "openclaw.gateway",title: "The OpenClaw Gateway is running",severity: .ok))
        } catch {
            d.reachable = false
            d.items.append(Readiness.Item(id: "openclaw.gateway",title: PlainError.describe(error)?.title ?? "The OpenClaw Gateway isn't answering",detail: error.localizedDescription,severity: .warning,fix: .copy(title: "Copy start command",command: "openclaw gateway run")))
        }
        return d
    }
    static let inApp = Readiness.Item(id: "openclaw.gateway",title: "Gateway checks are left to the Yorozu app",detail: "This process was started from an OpenClaw agent's shell, so it makes no Gateway calls. Open Yorozu from Finder and finish setup there.",severity: .warning,fix: .step("harness"))

    public func executors(_ settings: HarnessSettings) -> [CodingExecutor] {
        OpenClawHarness(workspace: URL(fileURLWithPath: "/"),agent: agent,settings: { settings }).executors.map { CodingExecutor(executor: $0,binary: $0.id,path: Self.which($0.id,extra: ["~/.local/bin"])) }
    }

    /// Read-only: Yorozu's entry, the role models, provider auth, and the assisted write that would fix what a write can.
    /// Calls `config.get`, `models.list` (configured, and all only when a role model is missing) and `models.authStatus`.
    public func inspect(_ settings: ResolvedSettings, dataRoot: URL) async throws -> OpenClawInspection {
        let snapshot = try await rpc.call("config.get",[:],timeout: Self.probe)
        guard let hash = snapshot["hash"] as? String, let config = snapshot["config"] as? [String:Any] else { throw ProjectError.uncertain("OpenClaw's config could not be read (config.get).") }
        let c = settings.config, agents = config["agents"] as? [String:Any] ?? [:], entries = agents["entries"] as? [String:Any] ?? [:]
        let entry = entries[agent] as? [String:Any], base = "agents.entries.\(agent)"
        var out = OpenClawInspection(), patch: [String:Any] = [:], changes: [OpenClawPlan.Change] = [], replace: [String] = []
        func change(_ key: String, _ value: Any?, old: Any?, path: String? = nil) {
            let path = path ?? base + "." + key
            changes.append(.init(path: path,old: old.map(json),new: value.map(json)))
            if let old { replace += OpenClawHarness.arrayPaths(old,path) }
        }

        // Yorozu's own entry in today's shape (docs/setup.md); nothing else in it is inspected.
        let workspace = c.harness.devRepoURL ?? Self.workspace(dataRoot)
        var shape: [String] = []
        if let entry {
            out.entry.append(Readiness.Item(id: "openclaw.agent",title: "Yorozu's agent \(agent) is set up in OpenClaw",severity: .ok))
            if Self.normalized(entry["workspace"] as? String) != workspace.standardizedFileURL.path { shape.append("workspace") }
            if Self.primary(entry["model"]) == nil, Self.primary(c.models.worker) ?? Self.primary((agents["defaults"] as? [String:Any])?["model"]) != nil { shape.append("model") }
            if entry["contextInjection"] as? String != "never" { shape.append("contextInjection") }
            if (entry["skills"] as? [Any])?.isEmpty != true { shape.append("skills") }
            if ((entry["subagents"] as? [String:Any])?["allowAgents"] as? [Any])?.isEmpty != true { shape.append("subagents") }
            if entry["tools"] != nil { shape.append("tools") }
        } else {
            out.entry.append(Readiness.Item(id: "openclaw.agent",title: "Yorozu's agent isn't set up in OpenClaw",detail: "agents.entries.\(agent) is missing.",severity: .warning,fix: .step("harness")))
            // A second entry is valid only in an explicit roster; Yorozu never writes agents.ownership, so OpenClaw adds it.
            let explicit = agents["ownership"] as? String == "explicit" || entries.values.contains { ($0 as? [String:Any])?["default"] as? Bool == true }
            if !explicit || entries.isEmpty {
                out.blocked = Readiness.Item(id: "openclaw.roster",title: "Add Yorozu's agent with OpenClaw first",detail: "OpenClaw's agent list isn't in explicit mode (agents.ownership), and Yorozu writes only its own entry. Add the agent with OpenClaw, then run setup again.",severity: .warning,
                                             fix: .copy(title: "Copy command",command: "openclaw agents add \(agent) --non-interactive --workspace \(Self.quoted(workspace.path))"))
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
            out.entry.append(Readiness.Item(id: "openclaw.agent.shape",title: "Yorozu's agent \(agent) differs from what Yorozu expects",detail: changes.map(\.line).joined(separator: "\n"),severity: .warning,fix: .step("harness")))
        } else if entry != nil {
            out.entry.append(Readiness.Item(id: "openclaw.agent.shape",title: "Yorozu's agent has the expected settings",severity: .ok))
        }
        let confirm = entry != nil && !changes.isEmpty

        // Role models: usable when models.list (configured, so the agent's model policy applies) lists them available.
        var used = Set<String>()
        if entry != nil {
            do {
                let rows = try await rpc.call("models.list",["agentId":agent,"view":"configured","includeDetails":true],timeout: Self.probe)["models"] as? [[String:Any]] ?? []
                let meta = OpenClawHarness.models(rows,config: config)
                let m = settings.models(meta.allowed,primary: meta.primary,runtimes: Dictionary(executors(HarnessSettings()).compactMap { e in e.executor.runtime.map { (e.executor.id,$0) } }) { a,_ in a })
                var roles = [("Secretary",m.secretary),("Memory extraction",m.extraction),("Worker",m.worker),("Review",m.review)]
                if c.harness.devRepoURL != nil { roles += m.coding.sorted { $0.key < $1.key }.map { ("Coding (\($0.key))",$0.value) } }
                let byID = Dictionary(rows.map { ("\($0["provider"] as? String ?? "")/\($0["id"] as? String ?? "")",$0) }) { a,_ in a }
                var missing: [String] = []
                used = Set(roles.compactMap { $0.1.id?.split(separator: "/").first.map(String.init) })
                for (role,choice) in roles {
                    guard let id = choice.id else { out.models.append(Readiness.Item(id: "openclaw.model.\(role)",title: "No model is set for \(role)",detail: choice.reason,severity: .warning,fix: .step("models"))); continue }
                    if let row = byID[id] {
                        let reason = row["unavailableReason"] as? String
                        out.models.append(row["available"] as? Bool == false
                            ? Readiness.Item(id: "openclaw.model.\(role)",title: "\(role): \(id) can't be used right now",detail: reason ?? "unavailable",severity: .warning,fix: reason == "cooldown" ? nil : .copy(title: "Copy sign-in command",command: "openclaw models auth login --agent \(agent) --provider \(id.split(separator: "/").first ?? "")"))
                            : Readiness.Item(id: "openclaw.model.\(role)",title: "\(role): \(id)",severity: .ok))
                    } else { missing.append(id) }
                }
                missing = Array(Set(missing)).sorted()
                if !missing.isEmpty {
                    // Known to OpenClaw but outside the agent's policy: the assisted write adds them to Yorozu's own allow list.
                    let all = Set((try await rpc.call("models.list",["agentId":agent,"view":"all"],timeout: Self.probe)["models"] as? [[String:Any]] ?? []).map { "\($0["provider"] as? String ?? "")/\($0["id"] as? String ?? "")" })
                    let policy = ((entry?["modelPolicy"] as? [String:Any])?["allow"] ?? (((agents["defaults"] as? [String:Any])?["modelPolicy"] as? [String:Any])?["allow"])) as? [String] ?? []
                    let allowable = policy.isEmpty ? [] : missing.filter(all.contains) // an empty policy allows any model: a list would narrow it
                    for id in missing {
                        out.models.append(Readiness.Item(id: "openclaw.model.\(id)",title: "OpenClaw doesn't allow \(id) for Yorozu",detail: all.contains(id) ? "Not in agent \(agent)'s model policy." : "OpenClaw doesn't list \(id).",severity: .warning,fix: .step("models")))
                    }
                    if !allowable.isEmpty {
                        // Seeded from the policy in force (the entry's, else the defaults'), since an entry's own list replaces the defaults.
                        let old = (entry?["modelPolicy"] as? [String:Any])?["allow"], next = policy + allowable.filter { !policy.contains($0) }
                        patch["modelPolicy"] = ["allow": next]; change("modelPolicy",next,old: old,path: base + ".modelPolicy.allow")
                    }
                }
            } catch {
                out.models.append(Readiness.Item(id: "openclaw.models",title: PlainError.describe(error)?.title ?? "OpenClaw's models couldn't be read",detail: error.localizedDescription,severity: .warning,fix: .step("models")))
            }
            // Provider auth for the role models' providers: the provider and its state only.
            if let providers = try? await rpc.call("models.authStatus",["agentId":agent],timeout: Self.probe)["providers"] as? [[String:Any]] {
                for p in providers {
                    guard let id = p["provider"] as? String, used.contains(id) else { continue }
                    let name = p["displayName"] as? String ?? id, status = p["status"] as? String ?? "unknown", fine = ["ok","static"].contains(status)
                    out.auth.append(Readiness.Item(id: "openclaw.auth.\(id)",title: name + (fine ? ": signed in" : status == "expiring" ? ": sign-in expires soon" : status == "expired" ? ": sign-in expired" : ": not signed in"),detail: "\(id): \(status)",severity: fine ? .ok : .warning,
                                                   fix: fine ? nil : .copy(title: "Copy sign-in command",command: "openclaw models auth login --agent \(agent) --provider \(id)")))
                }
            }
        } else {
            out.models.append(Readiness.Item(id: "openclaw.models",title: "Models are checked once Yorozu's agent is set up",severity: .warning,fix: .step("harness")))
        }

        // Yorozu's MCP servers, through the mirror's own patch.
        let configured = (config["mcp"] as? [String:Any])?["servers"] as? [String:Any] ?? [:]
        let (mcp,mcpReplace) = OpenClawHarness.mcpPatch(c.effectiveMCPServers,configured: configured)
        for key in mcp.keys.sorted() { changes.append(.init(path: "mcp.servers." + key,old: configured[key].map(json),new: mcp[key] is NSNull ? nil : mcp[key].map(json))) }
        replace += mcpReplace

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

    /// The empty Yorozu-owned workspace used while coding is off (no `dev_repo`).
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
    var raw = "", replacePaths: [String] = [], baseHash = ""
    /// The workspace the write sets, created first when it is Yorozu's own folder.
    var workspace: URL?
}

private func json(_ value: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: value,options: [.sortedKeys,.fragmentsAllowed,.withoutEscapingSlashes])).map { String(decoding: $0,as: UTF8.self) } ?? "\(value)"
}
