import Foundation
import TOML

/// Yorozu's settings: `config.toml` in the data root in use (#312). Unknown keys are kept as data; Yorozu rewrites the
/// whole file in its canonical, commented layout, so hand-written comments are not kept.
public struct Config: Sendable, Equatable {
    public enum SendKey: String, CaseIterable, Sendable { case smart, cmdEnter = "cmd-enter" }
    public enum Appearance: String, CaseIterable, Sendable { case system, light, dark }
    public enum Destination: String, CaseIterable, Sendable { case mac, phones }
    public enum Transport: String, CaseIterable, Sendable { case native, cli }
    public enum HarnessKind: String, CaseIterable, Sendable { case openclaw, hermes }
    public struct General: Sendable, Equatable {
        public var startAtLogin = true, keepMacAwake = false, yolo = false, sendKey = SendKey.cmdEnter, globalShortcut = "", appearance = Appearance.system, showAdvanced = false
    }
    public struct Notifications: Sendable, Equatable { public var enabled = true, destination = Destination.mac }
    public struct Routing: Sendable, Equatable { public var personalKnowledge = "", selfTopic = "Yorozu" }
    public struct Relay: Sendable, Equatable { public var url = "wss://relay.yumi.to" }
    public struct Direct: Sendable, Equatable { public var enabled = true, port = 8738 }
    public struct HarnessSettings: Sendable, Equatable {
        public var kind = HarnessKind.openclaw, agent = "yorozu", transport = Transport.native, gatewayURL = "ws://127.0.0.1:18789", hermesURL = "http://127.0.0.1:8642"
        /// Retired with `dev_repo` and `dev_base` (#351): never read from or written to the file, where old keys stay as
        /// unknown data. Kept only until Settings › Advanced drops its coding-repository rows.
        @available(*, deprecated, message: "Retired in #351: coding runs in the workspace; dev_repo is ignored.")
        public var devRepo = "", devBase = ""
        @available(*, deprecated, message: "Retired in #351.")
        public var devRepoURL: URL? { nil }
    }
    /// Where workers and coding agents work (#351): one folder per task under `path`. `restrict` keeps them inside it.
    public struct Workspace: Sendable, Equatable {
        /// Empty is the default: `~/Yorozu/workspace`, or `<data root>/workspace` under `PROJECTX_DATA` or in fixture mode.
        public var path = "", restrict = false
        /// The workspace folder: `path` with `~/` expanded, else the default for `dataRoot` (`isolated`: `PROJECTX_DATA` or fixture mode).
        public func url(dataRoot: URL, isolated: Bool) -> URL {
            if !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,isDirectory: true).standardizedFileURL }
            return isolated ? dataRoot.appendingPathComponent("workspace",isDirectory: true) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Yorozu/workspace",isDirectory: true)
        }
    }
    /// A nil role or a missing executor is automatic (`ModelDefaults`).
    public struct Models: Sendable, Equatable {
        public var secretary, extraction, worker, review: String?; public var rules = Rules()
        /// Retired with the coding executors (#351): never read from or written to the file (`[models.coding]` stays as unknown data).
        public var coding: [String:String] = [:]
        public init() {}
    }
    public struct Rules: Sendable, Equatable { public var minContextTokens = 32000, minOutputTokens = 16000 }
    /// First-launch setup progress (`SetupEngine`): finished, and the steps the user answered or skipped.
    public struct SetupProgress: Sendable, Equatable { public var done = false, answered: [String] = [] }
    public var general = General(), notifications = Notifications(), routing = Routing(), relay = Relay(), direct = Direct(), harness = HarnessSettings(), workspace = Workspace(), models = Models(), setup = SetupProgress()
    /// The user's own `[mcp_servers]`; workers get `effectiveMCPServers`.
    public var mcpServers: [String:MCPServer] = [:]
    /// The user's own `[coding_agents.<name>]`; workers get `effectiveCodingAgents`.
    public var codingAgents: [String:CodingAgent] = [:]
    /// Built-ins (`Integration.builtIn`) plus the user's `[integrations.<name>]`, by name.
    public var integrations = Dictionary(uniqueKeysWithValues: Integration.builtIn.map { ($0.name,$0) })
    /// Keys Yorozu does not know, kept and written back as data.
    public var extra: [String:TOMLValue] = [:]
    /// Dotted keys the file set (`mcp_servers` for the whole list), for `SettingSource.file`.
    public internal(set) var fileKeys: Set<String> = []
    public init() {}

    /// Enabled integrations by name.
    public var enabledIntegrations: [Integration] { integrations.values.filter(\.enabled).sorted { $0.name < $1.name } }
    /// What the harness adapters mirror: `[mcp_servers]` plus the servers of enabled integrations, deduped by name with
    /// `[mcp_servers]` winning. A server name a disabled integration declares is dropped from `[mcp_servers]` too, so
    /// switching cua off removes cua-driver even where an older file lists it there.
    public var effectiveMCPServers: [String:MCPServer] {
        let off = Set(integrations.values.filter { !$0.enabled }.flatMap(\.mcpServers.keys))
        return enabledIntegrations.reduce(mcpServers.filter { !off.contains($0.key) }) { list,i in list.merging(i.mcpServers) { mine,_ in mine } }
    }

    /// The coding agents workers may run (#351): the built-ins plus `[coding_agents]`, an entry of the same name replacing a built-in, by name.
    public var effectiveCodingAgents: [CodingAgent] {
        CodingAgent.builtIn.filter { codingAgents[$0.name] == nil } + codingAgents.values.sorted { $0.name < $1.name }
    }

    public static func url(in root: URL) -> URL { root.appendingPathComponent("config.toml") }
    /// The data root holding `config.toml`: `PROJECTX_DATA`, else `~/Library/Application Support/<bundle id>` (its
    /// `Fixture` folder in fixture mode). `support` is that Application Support folder whatever `PROJECTX_DATA` says.
    public static func dataRoot(_ environment: [String:String], bundleID: String) throws -> (root: URL, support: URL, explicit: Bool) {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent(bundleID,isDirectory: true)
        if let dir = environment["PROJECTX_DATA"] { return (URL(fileURLWithPath: dir,isDirectory: true),support,true) }
        return (RuntimeMode.from(environment) == .fixture ? support.appendingPathComponent("Fixture",isDirectory: true) : support,support,false)
    }

    /// The validated file. A missing file is written with the defaults, plus the entries of a retired
    /// `mcp-servers.json` in the same folder.
    public static func load(_ url: URL) throws -> Config {
        try parse(String(decoding: try read(url),as: UTF8.self),file: url)
    }
    /// The file's bytes, first writing the defaults when it is missing (see `load`).
    public static func read(_ url: URL) throws -> Data {
        if !FileManager.default.fileExists(atPath: url.path) {
            var fresh = Config()
            if let legacy = MCPServers.legacy(url.deletingLastPathComponent().appendingPathComponent("mcp-servers.json")) { fresh.mcpServers = legacy }
            try fresh.write(url,replace: false)
        }
        do { return try Data(contentsOf: url) } catch { throw ConfigError(file: url.path,reason: error.localizedDescription) }
    }
    /// Read-modify-write: reads the file fresh, so an edit made since the last load is kept. Serialized in this process
    /// and, through `flock` on `.config.toml.lock` beside the file, with the app and `Yorozu setup` in other processes.
    @discardableResult public static func update(_ url: URL, _ change: (inout Config) throws -> Void) throws -> Config {
        lock.lock(); defer { lock.unlock() }
        let folder = url.deletingLastPathComponent(), lockFile = folder.appendingPathComponent(".config.toml.lock").path
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let fd = open(lockFile,O_RDWR | O_CREAT | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw ConfigError(file: url.path,reason: "could not open \(lockFile): " + String(cString: strerror(errno))) }
        defer { close(fd) } // closing releases the lock
        guard flock(fd,LOCK_EX) == 0 else { throw ConfigError(file: url.path,reason: "could not lock \(lockFile): " + String(cString: strerror(errno))) }
        var config = try load(url); try change(&config); try config.write(url); return try load(url)
    }
    private static let lock = NSLock()
    /// Atomic (temporary file, fsync, then rename), mode 0600; refuses an invalid config.
    public func write(_ url: URL, replace: Bool = true) throws {
        if let (key,reason) = problem() { throw ConfigError(file: url.path,key: key,reason: reason) }
        let folder = url.deletingLastPathComponent(), temp = folder.appendingPathComponent(".config.toml." + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: temp.path,contents: Data(toml().utf8),attributes: [.posixPermissions: 0o600]) else { throw ConfigError(file: url.path,reason: "could not write \(temp.path)") }
        do { let handle = try FileHandle(forWritingTo: temp); defer { try? handle.close() }; try handle.synchronize() }
        catch { try? FileManager.default.removeItem(at: temp); throw ConfigError(file: url.path,reason: error.localizedDescription) }
        guard renamex_np(temp.path,url.path,replace ? 0 : UInt32(RENAME_EXCL)) == 0 else {
            let code = errno; try? FileManager.default.removeItem(at: temp)
            if code == EEXIST { return }; throw ConfigError(file: url.path,reason: String(cString: strerror(code)))
        }
    }

    // MARK: Keys
    struct Field { let key, note, expected: String; let get: (Config) -> TOMLValue?; let set: (inout Config, TOMLValue) -> Bool }
    static func field<V: TOMLScalar>(_ key: String, _ path: WritableKeyPath<Config,V>, _ note: String) -> Field {
        Field(key: key,note: note,expected: V.expected,get: { $0[keyPath: path].toml },set: { config,value in guard let v = V(toml: value) else { return false }; config[keyPath: path] = v; return true })
    }
    static let security = " Security-relevant: ask the user before changing it."
    static let fields = [
        field("general.start_at_login",\.general.startAtLogin,"Open Yorozu when you log in."),
        field("general.keep_mac_awake",\.general.keepMacAwake,"Keep the Mac from idle sleep while Yorozu runs; a closed lid still sleeps."),
        field("general.yolo",\.general.yolo,"YOLO: workers take outward-facing steps you asked for, and use risky cua tools, without asking first. Settings changes and unrequested actions still need your word." + security),
        field("general.send_key",\.general.sendKey,"\"cmd-enter\" (the default: Enter adds a line, ⌘Enter sends) or \"smart\" (Enter sends a one-line draft)."),
        field("general.global_shortcut",\.general.globalShortcut,"Shortcut that brings up Yorozu; empty is off."),
        field("general.appearance",\.general.appearance,"\"system\", \"light\" or \"dark\"."),
        field("general.show_advanced",\.general.showAdvanced,"Show the Advanced tab in Settings."),
        field("notifications.enabled",\.notifications.enabled,"Post notifications."),
        field("notifications.destination",\.notifications.destination,"Where notifications appear: \"mac\" (the host) or \"phones\" (client devices)."),
        field("routing.personal_knowledge",\.routing.personalKnowledge,"Where the user's personal notes live, named in the routing policy; empty drops that hint."),
        field("routing.self_topic",\.routing.selfTopic,"Topic that holds work on Yorozu itself."),
        field("relay.url",\.relay.url,"Relay for client devices (ws:// or wss://). After a change every client device must pair again." + security),
        field("direct.enabled",\.direct.enabled,"Let client devices connect straight to the host over the local network or a VPN (Tailscale/WireGuard); a client tries only after its own Direct connection setting is on." + security),
        field("direct.port",\.direct.port,"TCP port the direct listener uses on Wi-Fi, Ethernet and VPN interfaces (1024-65535)." + security),
        field("harness.kind",\.harness.kind,"Main harness: \"openclaw\" or \"hermes\"; applies after relaunch, and only once no work is running." + security),
        field("harness.agent",\.harness.agent,"Harness agent id Yorozu runs on." + security),
        field("harness.transport",\.harness.transport,"\"native\" (WebSocket client) or \"cli\" (openclaw CLI); applies after relaunch." + security),
        field("harness.gateway_url",\.harness.gatewayURL,"Gateway address, loopback only; applies after relaunch." + security),
        field("harness.hermes_url",\.harness.hermesURL,"Hermes Agent API server, loopback only with no path; applies after relaunch." + security),
        field("workspace.path",\.workspace.path,"Folder where agents work, one subfolder per task; downloads and clones go there. Empty is ~/Yorozu/workspace (<data root>/workspace under PROJECTX_DATA or in fixture mode)." + security),
        field("workspace.restrict",\.workspace.restrict,"Keep agents inside the workspace: workers are told to, and Yorozu runs coding agents only in folders inside it. Off: file access is not limited." + security),
        field("models.secretary",\.models.secretary,"Secretary model (provider/model); leave out for automatic." + security),
        field("models.extraction",\.models.extraction,"Memory extraction model; leave out for automatic." + security),
        field("models.worker",\.models.worker,"Worker model; leave out for automatic." + security),
        field("models.review",\.models.review,"Stronger review model; leave out for automatic." + security),
        field("models.rules.min_context_tokens",\.models.rules.minContextTokens,"Smallest context window for the automatic secretary and extraction model."),
        field("models.rules.min_output_tokens",\.models.rules.minOutputTokens,"Smallest output cap for the automatic secretary and extraction model."),
        field("setup.done",\.setup.done,"Setup is finished; until it is, Yorozu opens the setup window at launch."),
        field("setup.answered",\.setup.answered,"Setup steps answered or skipped, by id."),
    ]
    static let sections = [
        "general": "General.", "notifications": "Notifications.", "routing": "Routing hints for the secretary.", "relay": "Relay for client devices.", "direct": "Direct client connection over LAN or VPN.",
        "harness": "Harness connection.", "models": "Models per role; a missing role is chosen automatically from the harness's model metadata.",
        "workspace": "Workspace for workers and coding agents.",
        "coding_agents": "Coding agents workers run through Yorozu: [coding_agents.<name>] with command (the program and its arguments; the prompt is added as the last argument) and optional timeout (seconds, default 3600). Built-in: claude and codex, offered when found; an entry with the same name replaces it." + security,
        "models.rules": "Inputs of the automatic choice.", "setup": "First-launch setup progress (Yorozu setup, or the setup window).",
        "mcp_servers": "MCP servers workers may use: [mcp_servers.<name>] with command (absolute path) and args; env is not supported." + security,
        "integrations": "Integrations: MCP servers, worker rules, checks and fixes as data, each with enabled = true or false. Built-in: [integrations.cua] (computer use through CuaDriver). Your own [integrations.<name>] may also set title, rules (\"{session}\" is the per-run cua session label), checks = [{ title, file or socket = \"/path\" }], fixes = [{ title, copy = \"command\" or url }], [integrations.<name>.mcp_servers.<server>] and [integrations.<name>.settings]." + security,
    ]
    /// Known keys and sections in file order.
    static let order: [String] = fields.flatMap { field in
        let parts = field.key.split(separator: ".")
        return (1..<parts.count).map { parts.prefix($0).joined(separator: ".") } + [field.key]
    }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } + ["mcp_servers","coding_agents","integrations"]

    // MARK: Read
    public static func parse(_ text: String, file: URL) throws -> Config {
        func fail(_ key: String?, _ reason: String, line: Int? = nil) -> ConfigError { ConfigError(file: file.path,line: line ?? key.flatMap { Self.line(of: $0,in: text) },key: key,reason: reason) }
        var tree: [String:TOMLValue]
        do { tree = try TOMLDecoder().decode([String:Node].self,from: text).mapValues(\.value) }
        catch let TOMLDecodingError.invalidSyntax(line,_,message) { throw fail(nil,message,line: line) }
        catch { throw fail(nil,"\(error)") }
        func take(_ table: inout [String:TOMLValue], _ path: ArraySlice<String>, _ key: String) throws -> TOMLValue? {
            guard path.count > 1 else { return table.removeValue(forKey: path.first!) }
            guard let next = table[path.first!] else { return nil }
            guard case .table(var sub) = next else { throw fail(key,"\(path.first!) must be a table") }
            defer { table[path.first!] = .table(sub) }; return try take(&sub,path.dropFirst(),key)
        }
        var config = Config()
        for field in fields {
            guard let value = try take(&tree,field.key.split(separator: ".").map(String.init)[...],field.key) else { continue }
            guard field.set(&config,value) else { throw fail(field.key,"expected \(field.expected)") }
            config.fileKeys.insert(field.key)
        }
        /// A `[<prefix>.<name>]` server list and each entry's unknown keys.
        func servers(_ raw: TOMLValue, _ prefix: String) throws -> ([String:MCPServer], [String:TOMLValue]) {
            guard case .table(let table) = raw else { throw fail(prefix,"expected [\(prefix).<name>] tables") }
            var list: [String:MCPServer] = [:], rest: [String:TOMLValue] = [:]
            for (name,value) in table {
                let key = "\(prefix).\(name)"
                guard case .table(var entry) = value, case .string(let command)? = entry.removeValue(forKey: "command") else { throw fail(key,"needs command = \"/absolute/path\"") }
                guard entry["env"] == nil else { throw fail(key,"env is not supported") }
                var args: [String]?
                if let raw = entry.removeValue(forKey: "args") {
                    guard case .array(let items) = raw, let strings = Optional(items.compactMap { if case .string(let s) = $0 { s } else { nil } }), strings.count == items.count else { throw fail(key + ".args","expected an array of strings") }
                    args = strings
                }
                list[name] = MCPServer(command: command,args: args)
                if !entry.isEmpty { rest[name] = .table(entry) }
            }
            return (list,rest)
        }
        if let raw = try take(&tree,["mcp_servers"],"mcp_servers") {
            let (list,rest) = try servers(raw,"mcp_servers")
            config.mcpServers = list; config.fileKeys.insert("mcp_servers")
            if !rest.isEmpty { tree["mcp_servers"] = .table(rest) }
        }
        if let raw = try take(&tree,["coding_agents"],"coding_agents") {
            guard case .table(let table) = raw else { throw fail("coding_agents","expected [coding_agents.<name>] tables") }
            var rest: [String:TOMLValue] = [:]
            for (name,value) in table {
                let key = "coding_agents.\(name)"
                guard case .table(var entry) = value, let raw = entry.removeValue(forKey: "command"), let command = [String](toml: raw) else { throw fail(key,"needs command = [\"program\", \"argument\", …]") }
                var agent = CodingAgent(name: name,command: command)
                if let t = entry.removeValue(forKey: "timeout") { guard let seconds = Int(toml: t) else { throw fail(key + ".timeout","expected an integer") }; agent.timeout = seconds }
                config.codingAgents[name] = agent; config.fileKeys.insert(key)
                if !entry.isEmpty { rest[name] = .table(entry) }
            }
            if !rest.isEmpty { tree["coding_agents"] = .table(rest) }
        }
        if let raw = try take(&tree,["integrations"],"integrations") {
            guard case .table(let table) = raw else { throw fail("integrations","expected [integrations.<name>] tables") }
            var rest: [String:TOMLValue] = [:]
            for (name,value) in table {
                let key = "integrations.\(name)", builtIn = Integration.builtIn.contains { $0.name == name }
                guard case .table(var entry) = value else { throw fail(key,"expected a table") }
                var item = config.integrations[name] ?? Integration(name: name)
                func string(_ field: String) throws -> String? {
                    guard let v = entry.removeValue(forKey: field) else { return nil }
                    guard case .string(let s) = v else { throw fail("\(key).\(field)","expected a string") }; return s
                }
                /// An array of tables, each with a string `title` and exactly one string value among `kinds`.
                func items(_ field: String, _ kinds: [String], _ rule: String) throws -> [(title: String, kind: String, value: String)]? {
                    guard let v = entry.removeValue(forKey: field) else { return nil }
                    guard case .array(let list) = v else { throw fail("\(key).\(field)",rule) }
                    return try list.map { item in
                        guard case .table(let t) = item, case .string(let title)? = t["title"], t.count == 2, let kind = kinds.first(where: { t[$0] != nil }), case .string(let s)? = t[kind] else { throw fail("\(key).\(field)",rule) }
                        return (title,kind,s)
                    }
                }
                if let v = entry.removeValue(forKey: "enabled") {
                    guard case .boolean(let on) = v else { throw fail(key + ".enabled","expected true or false") }
                    item.enabled = on; config.fileKeys.insert(key + ".enabled")
                }
                if let v = entry.removeValue(forKey: "settings") { guard case .table(let t) = v else { throw fail(key + ".settings","expected a table") }; item.settings = t }
                if !builtIn { // a built-in's servers, rules, checks and fixes ship with the app; those keys stay as unknown data
                    if let title = try string("title") { item.title = title }
                    if let rules = try string("rules") { item.rules = rules }
                    if let v = entry.removeValue(forKey: "mcp_servers") {
                        let (list,extra) = try servers(v,key + ".mcp_servers"); item.mcpServers = list
                        if !extra.isEmpty { entry["mcp_servers"] = .table(extra) }
                    }
                    if let checks = try items("checks",["file","socket"],"expected [{ title = \"…\", file = \"/path\" }] or socket = \"/path\"; your own integrations may declare only file and socket checks") {
                        item.checks = checks.map { Integration.Check(title: $0.title,kind: $0.kind == "file" ? .file($0.value) : .socket($0.value)) }
                    }
                    if let fixes = try items("fixes",["copy","url"],"expected [{ title = \"…\", copy = \"command\" }] or url = \"https://…\"") {
                        item.fixes = try fixes.map { f in
                            if f.kind == "copy" { return .copy(title: f.title,command: f.value) }
                            guard let url = URL(string: f.value) else { throw fail(key + ".fixes","expected an http:// or https:// URL") }; return .open(title: f.title,url: url)
                        }
                    }
                }
                config.integrations[name] = item; config.fileKeys.insert(key)
                if !entry.isEmpty { rest[name] = .table(entry) }
            }
            if !rest.isEmpty { tree["integrations"] = .table(rest) }
        }
        // A file from before integrations whose [mcp_servers] had cua-driver removed meant computer use off.
        if config.fileKeys.contains("mcp_servers"), !config.fileKeys.contains("integrations.cua.enabled"), config.mcpServers["cua-driver"] == nil { config.integrations["cua"]?.enabled = false }
        config.extra = tree
        if let (key,reason) = config.problem() { throw fail(key,reason) }
        return config
    }
    /// Dotted keys of security-relevant settings that differ from `old`, for the "Settings changed" notice.
    public func securityChanges(from old: Config) -> [String] {
        Self.fields.filter { $0.note.hasSuffix(Self.security) && $0.get(self) != $0.get(old) }.map(\.key)
            + (codingAgents != old.codingAgents ? ["coding_agents"] : []) + (mcpServers != old.mcpServers ? ["mcp_servers"] : [])
            + (integrations != old.integrations ? ["integrations"] : [])
    }
    /// The first invalid value as (dotted key, reason).
    func problem() -> (String, String)? {
        let h = harness
        if h.agent.range(of: "^[A-Za-z0-9_-]{1,64}$",options: .regularExpression) == nil { return ("harness.agent","expected 1-64 letters, digits, - or _") }
        if !Self.isLoopbackGateway(h.gatewayURL) { return ("harness.gateway_url","expected a loopback ws:// or wss:// address with no path, such as ws://127.0.0.1:18789") }
        if !Self.isLoopbackHTTP(h.hermesURL) { return ("harness.hermes_url","expected a loopback http:// or https:// address with no path, such as http://127.0.0.1:8642") }
        if !(workspace.path.isEmpty || workspace.path.hasPrefix("/") || workspace.path.hasPrefix("~/")) { return ("workspace.path","expected an absolute path, a ~/ path or \"\"") }
        for a in codingAgents.values.sorted(by: { $0.name < $1.name }) {
            let key = "coding_agents.\(a.name)"
            if a.name.range(of: "^[A-Za-z0-9_-]{1,64}$",options: .regularExpression) == nil { return (key,"expected a name of 1-64 letters, digits, - or _") }
            if a.command.first?.isEmpty != false { return (key + ".command","expected a program and its arguments") }
            if a.timeout < 1 { return (key + ".timeout","expected a positive number of seconds") }
        }
        if let url = URLComponents(string: relay.url), ["ws","wss"].contains(url.scheme ?? ""), !(url.host ?? "").isEmpty {} else { return ("relay.url","expected a ws:// or wss:// address") }
        for (key,model) in [("secretary",models.secretary),("extraction",models.extraction),("worker",models.worker),("review",models.review)] where model?.isEmpty == true { return ("models.\(key)","expected \"provider/model\"; leave the key out for automatic") }
        if !(1024...65535).contains(direct.port) { return ("direct.port","expected a port from 1024 to 65535") }
        if routing.selfTopic.count > 80 { return ("routing.self_topic","expected at most 80 characters") }
        if routing.personalKnowledge.utf8.count > 200 { return ("routing.personal_knowledge","expected at most 200 bytes of UTF-8") }
        if models.rules.minContextTokens < 1 { return ("models.rules.min_context_tokens","expected a positive integer") }
        if models.rules.minOutputTokens < 1 { return ("models.rules.min_output_tokens","expected a positive integer") }
        if let name = MCPServers.invalid(mcpServers) { return ("mcp_servers.\(name)",MCPServers.rule) }
        for i in integrations.values.sorted(by: { $0.name < $1.name }) {
            let key = "integrations.\(i.name)", shipped = Integration.builtIn.first { $0.name == i.name }
            if i.name.range(of: "^[A-Za-z0-9_-]{1,64}$",options: .regularExpression) == nil { return (key,"expected a name of 1-64 letters, digits, - or _") }
            if let name = MCPServers.invalid(i.mcpServers) { return ("\(key).mcp_servers.\(name)",MCPServers.rule) }
            if i.checks != shipped?.checks, i.checks.contains(where: { if case .command = $0.kind { true } else { false } }) { return (key + ".checks","only built-in integrations may run commands") }
            for case .open(_,let url) in i.fixes where !["http","https"].contains(url.scheme ?? "") { return (key + ".fixes","expected an http:// or https:// URL") }
        }
        return nil
    }
    /// The Gateway URL rule the CLI transport enforces: loopback host, ws or wss, no credentials, path, query or fragment.
    public static func isLoopbackGateway(_ target: String) -> Bool {
        isLoopback(target,schemes: ["ws","wss"])
    }
    /// The Hermes URL rule: loopback host, http or https, no credentials, path, query or fragment.
    public static func isLoopbackHTTP(_ target: String) -> Bool {
        isLoopback(target,schemes: ["http","https"])
    }
    /// IPv6 loopback may come back bracketed ("[::1]") from `URLComponents.host`; port 0 is never a listening port.
    static func isLoopback(_ target: String,schemes: Set<String>) -> Bool {
        guard let url = URLComponents(string: target) else { return false }
        return schemes.contains(url.scheme ?? "") && ["127.0.0.1","::1","[::1]","localhost"].contains(url.host ?? "") && url.port != 0 && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && ["","/"].contains(url.path)
    }
    /// Best effort: the line that sets `key` (or its table header).
    static func line(of key: String, in text: String) -> Int? {
        var parts = key.split(separator: ".").map(String.init); let name = parts.removeLast(), section = parts.joined(separator: ".")
        var current = ""
        for (index,raw) in text.split(separator: "\n",omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = String(line.drop { $0 == "[" }.prefix { $0 != "]" }).replacingOccurrences(of: "\"",with: "").replacingOccurrences(of: " ",with: "")
                if current == key { return index + 1 }; continue
            }
            let lhs = line.prefix { $0 != "=" }.replacingOccurrences(of: "\"",with: "").replacingOccurrences(of: " ",with: "")
            if line.contains("="), (current == section && lhs == name) || (current.isEmpty ? lhs : current + "." + lhs) == key { return index + 1 }
        }
        return nil
    }

    // MARK: Write
    /// The canonical file: known keys in order with a comment each, missing optional keys as commented examples, unknown keys after.
    public func toml() -> String {
        var tree = extra
        if case .table(let rest)? = tree["mcp_servers"] { tree["mcp_servers"] = .table(rest.filter { mcpServers[$0.key] != nil }) } // extras of removed servers go too
        func put(_ table: inout [String:TOMLValue], _ path: ArraySlice<String>, _ value: TOMLValue) {
            guard path.count > 1 else { if case .table? = table[path.first!], case .table = value { return }; table[path.first!] = value; return }
            var sub: [String:TOMLValue] = if case .table(let t)? = table[path.first!] { t } else { [:] }
            put(&sub,path.dropFirst(),value); table[path.first!] = .table(sub)
        }
        for section in Self.sections.keys.sorted() { put(&tree,section.split(separator: ".").map(String.init)[...],.table([:])) }
        for field in Self.fields { if let value = field.get(self) { put(&tree,field.key.split(separator: ".").map(String.init)[...],value) } }
        func servers(_ list: [String:MCPServer], _ path: [String]) {
            for (name,server) in list {
                put(&tree,(path + [name,"command"])[...],.string(server.command))
                if let args = server.args { put(&tree,(path + [name,"args"])[...],.array(args.map { .string($0) })) }
            }
        }
        servers(mcpServers,["mcp_servers"])
        if case .table(let rest)? = tree["coding_agents"] { tree["coding_agents"] = .table(rest.filter { codingAgents[$0.key] != nil }) }
        for (name,a) in codingAgents {
            put(&tree,["coding_agents",name,"command"],.array(a.command.map { .string($0) }))
            if a.timeout != CodingAgent.defaultTimeout { put(&tree,["coding_agents",name,"timeout"],.integer(Int64(a.timeout))) }
        }
        if case .table(let rest)? = tree["integrations"] { tree["integrations"] = .table(rest.filter { integrations[$0.key] != nil }) }
        for (name,i) in integrations {
            let path = ["integrations",name]
            put(&tree,(path + ["enabled"])[...],.boolean(i.enabled))
            if !i.settings.isEmpty { put(&tree,(path + ["settings"])[...],.table(i.settings)) }
            if Integration.builtIn.contains(where: { $0.name == name }) { continue } // the rest ships with the app
            if i.title != name { put(&tree,(path + ["title"])[...],.string(i.title)) }
            if !i.rules.isEmpty { put(&tree,(path + ["rules"])[...],.string(i.rules)) }
            let checks: [TOMLValue] = i.checks.compactMap { c in
                switch c.kind { case .file(let p): .table(["title": .string(c.title),"file": .string(p)]); case .socket(let p): .table(["title": .string(c.title),"socket": .string(p)]); case .command: nil }
            }
            if !checks.isEmpty { put(&tree,(path + ["checks"])[...],.array(checks)) }
            let fixes: [TOMLValue] = i.fixes.map { f in
                switch f { case .copy(let t,let c): .table(["title": .string(t),"copy": .string(c)]); case .open(let t,let u): .table(["title": .string(t),"url": .string(u.absoluteString)]) }
            }
            if !fixes.isEmpty { put(&tree,(path + ["fixes"])[...],.array(fixes)) }
            servers(i.mcpServers,path + ["mcp_servers"])
        }
        var out = "# Yorozu settings. Yorozu rewrites this file in this layout: unknown keys are kept, added comments are not.\n# PROJECTX_* environment variables override these values.\n"
        func emit(_ table: [String:TOMLValue], _ path: [String]) {
            let dot = path.isEmpty ? "" : path.joined(separator: ".") + "."
            let rank = path.count == 2 && path[0] == "coding_agents" ? ["command","timeout"] : path.count == 2 && path[0] == "mcp_servers" || path.count == 4 && path[0] == "integrations" && path[2] == "mcp_servers" ? ["command","args"]
                : path.count == 2 && path[0] == "integrations" ? ["enabled","title","rules","checks","fixes"] : Self.order.filter { $0.hasPrefix(dot) && !$0.dropFirst(dot.count).contains(".") }.map { String($0.dropFirst(dot.count)) }
            let keys = rank + table.keys.filter { !rank.contains($0) }.sorted()
            for key in keys {
                let note = Self.fields.first { $0.key == dot + key }?.note
                switch table[key] {
                case .table?: continue
                case let value?: out += (note.map { "# \($0)\n" } ?? "") + "\(Self.bare(key)) = \(Self.literal(value))\n"
                case nil: if let note { out += "# \(note)\n# \(key) = \"provider/model\"\n" } // only optional keys can be missing
                }
            }
            for key in keys { if case .table(let sub)? = table[key] {
                let child = path + [key], name = child.joined(separator: ".")
                if sub.isEmpty || Self.sections[name] != nil || sub.values.contains(where: { if case .table = $0 { false } else { true } }) {
                    out += "\n" + (Self.sections[name].map { "# \($0)\n" } ?? "") + "[\(child.map(Self.bare).joined(separator: "."))]\n"
                }
                emit(sub,child)
            } }
        }
        emit(tree,[])
        return out
    }
    static func bare(_ key: String) -> String { key.range(of: "^[A-Za-z0-9_-]+$",options: .regularExpression) != nil ? key : literal(.string(key)) }
    static func literal(_ value: TOMLValue) -> String {
        func two(_ n: Int) -> String { String(format: "%02d",n) }
        func time(_ h: Int, _ m: Int, _ s: Int, _ ns: Int) -> String { "\(two(h)):\(two(m)):\(two(s))" + (ns > 0 ? String(format: ".%09d",ns) : "") }
        switch value {
        case .string(let s):
            return "\"" + s.unicodeScalars.map { c -> String in
                switch c { case "\"": return "\\\""; case "\\": return "\\\\"; case "\n": return "\\n"; case "\t": return "\\t"; case "\r": return "\\r"
                default: return c.value < 0x20 || c.value == 0x7f ? String(format: "\\u%04X",c.value) : String(c) }
            }.joined() + "\""
        case .integer(let i): return "\(i)"
        case .float(let d): return d.isNaN ? "nan" : d.isInfinite ? (d < 0 ? "-inf" : "inf") : "\(d)"
        case .boolean(let b): return "\(b)"
        case .offsetDateTime(let date): let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.string(from: date)
        case .localDateTime(let t): return String(format: "%04d-%02d-%02dT",t.year,t.month,t.day) + time(t.hour,t.minute,t.second,t.nanosecond)
        case .localDate(let d): return String(format: "%04d-%02d-%02d",d.year,d.month,d.day)
        case .localTime(let t): return time(t.hour,t.minute,t.second,t.nanosecond)
        case .array(let items): return "[" + items.map(literal).joined(separator: ", ") + "]"
        case .table(let table): return table.isEmpty ? "{}" : "{ " + table.keys.sorted().map { "\(bare($0)) = \(literal(table[$0]!))" }.joined(separator: ", ") + " }"
        }
    }
}

/// A config problem for notices and Settings: file, line when known, dotted key when known, reason.
public struct ConfigError: Error, LocalizedError, Sendable, Equatable {
    public var file: String; public var line: Int?; public var key: String?; public var reason: String
    public init(file: String, line: Int? = nil, key: String? = nil, reason: String) { self.file = file; self.line = line; self.key = key; self.reason = reason }
    public var errorDescription: String? { (file as NSString).lastPathComponent + (line.map { " line \($0)" } ?? "") + (key.map { " (\($0))" } ?? "") + ": " + reason }
}

/// Where a resolved value came from, for Settings ("Set by PROJECTX_…").
public enum SettingSource: String, Sendable { case environment, file, automatic, `default` }
/// Effective settings: `PROJECTX_*` environment, then `config.toml`, then automatic (models), then the code default.
/// `PROJECTX_MODE` and `PROJECTX_DATA` stay environment-only (`RuntimeMode`, the data root).
public struct ResolvedSettings: Sendable, Equatable {
    public static let variables: [(String, [String])] = [
        ("PROJECTX_HARNESS",["harness.kind"]), ("PROJECTX_TRANSPORT",["harness.transport"]), ("PROJECTX_GATEWAY_URL",["harness.gateway_url"]), ("PROJECTX_AGENT",["harness.agent"]),
        ("PROJECTX_RELAY_URL",["relay.url"]),
        ("PROJECTX_SECRETARY_MODEL",["models.secretary","models.extraction"]), ("PROJECTX_MODEL",["models.worker"]), ("PROJECTX_REVIEW_MODEL",["models.review"]),
    ]
    /// The file's values with environment overrides applied.
    public private(set) var config: Config
    /// Dotted key → the variable that set it.
    public private(set) var environment: [String:String] = [:]
    public init(_ file: Config, environment env: [String:String] = ProcessInfo.processInfo.environment) throws {
        config = file
        for (name,keys) in Self.variables { guard let value = env[name] else { continue }
            for key in keys {
                if let field = Config.fields.first(where: { $0.key == key }), !field.set(&config,.string(value)) { throw ProjectError.invalid("\(name): expected \(field.expected).") }
                environment[key] = name
            }
        }
        if let (key,reason) = config.problem() { throw ProjectError.invalid("\(environment[key] ?? key): \(reason).") }
    }
    public func source(_ key: String) -> SettingSource {
        environment[key] != nil ? .environment : config.fileKeys.contains(key) ? .file : key.hasPrefix("models.") && !key.hasPrefix("models.rules.") ? .automatic : .default
    }
    /// Per-role models from the harness's metadata; explicit choices (environment or file) win. `runtimes` maps the
    /// harness's coding executors to their model runtimes (`Executor.runtime`).
    public func models(_ available: [ModelInfo], primary: String?, runtimes: [String:String] = [:]) -> ModelChoices { ModelDefaults.resolve(available,primary: primary,explicit: config.models,runtimes: runtimes) }
    public static func == (a: Self, b: Self) -> Bool { a.config == b.config && a.environment == b.environment }
}

protocol TOMLScalar { init?(toml: TOMLValue); var toml: TOMLValue? { get }; static var expected: String { get } }
extension String: TOMLScalar {
    init?(toml: TOMLValue) { guard case .string(let s) = toml else { return nil }; self = s }
    var toml: TOMLValue? { .string(self) }; static var expected: String { "a string" }
}
extension Bool: TOMLScalar {
    init?(toml: TOMLValue) { guard case .boolean(let b) = toml else { return nil }; self = b }
    var toml: TOMLValue? { .boolean(self) }; static var expected: String { "true or false" }
}
extension Int: TOMLScalar {
    init?(toml: TOMLValue) { guard case .integer(let i) = toml, let n = Int(exactly: i) else { return nil }; self = n }
    var toml: TOMLValue? { .integer(Int64(self)) }; static var expected: String { "an integer" }
}
extension Array: TOMLScalar where Element == String {
    init?(toml: TOMLValue) { guard case .array(let items) = toml else { return nil }; let s = items.compactMap { if case .string(let s) = $0 { s } else { nil } }; guard s.count == items.count else { return nil }; self = s }
    var toml: TOMLValue? { .array(map { .string($0) }) }; static var expected: String { "an array of strings" }
}
extension Optional: TOMLScalar where Wrapped: TOMLScalar {
    init?(toml: TOMLValue) { guard let w = Wrapped(toml: toml) else { return nil }; self = w }
    var toml: TOMLValue? { self?.toml }; static var expected: String { Wrapped.expected }
}
extension TOMLScalar where Self: RawRepresentable & CaseIterable, RawValue == String {
    init?(toml: TOMLValue) { guard case .string(let s) = toml, let v = Self(rawValue: s) else { return nil }; self = v }
    var toml: TOMLValue? { .string(rawValue) }; static var expected: String { "one of " + allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") }
}
extension Config.SendKey: TOMLScalar {}
extension Config.Appearance: TOMLScalar {}
extension Config.Destination: TOMLScalar {}
extension Config.Transport: TOMLScalar {}
extension Config.HarnessKind: TOMLScalar {}

/// Any TOML value, so unknown keys survive a round trip.
private struct Node: Decodable {
    let value: TOMLValue
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = .boolean(v) }
        else if let v = try? c.decode(Int64.self) { value = .integer(v) }
        else if let v = try? c.decode(Double.self) { value = .float(v) }
        else if let v = try? c.decode(String.self) { value = .string(v) }
        else if let v = try? c.decode(LocalDateTime.self) { value = .localDateTime(v) }
        else if let v = try? c.decode(LocalDate.self) { value = .localDate(v) }
        else if let v = try? c.decode(LocalTime.self) { value = .localTime(v) }
        else if let v = try? c.decode(Date.self) { value = .offsetDateTime(v) }
        else if let v = try? c.decode([Node].self) { value = .array(v.map(\.value)) }
        else { value = .table(try c.decode([String:Node].self).mapValues(\.value)) }
    }
}
