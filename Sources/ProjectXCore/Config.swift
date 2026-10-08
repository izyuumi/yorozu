import Foundation
import TOML

/// Yorozu's settings: `config.toml` in the data root in use (#312). Unknown keys are kept as data; Yorozu rewrites the
/// whole file in its canonical, commented layout, so hand-written comments are not kept.
public struct Config: Sendable, Equatable {
    public enum SendKey: String, CaseIterable, Sendable { case smart, cmdEnter = "cmd-enter" }
    public enum Appearance: String, CaseIterable, Sendable { case system, light, dark }
    public enum Destination: String, CaseIterable, Sendable { case mac, phones }
    public enum Transport: String, CaseIterable, Sendable { case native, cli }
    public enum HarnessKind: String, CaseIterable, Sendable { case openclaw }
    public struct General: Sendable, Equatable {
        public var startAtLogin = true, keepMacAwake = false, yolo = false, sendKey = SendKey.smart, globalShortcut = "", appearance = Appearance.system, showAdvanced = false
    }
    public struct Notifications: Sendable, Equatable { public var enabled = true, destination = Destination.mac }
    public struct Routing: Sendable, Equatable { public var personalKnowledge = "", selfTopic = "Yorozu" }
    public struct Relay: Sendable, Equatable { public var url = "wss://relay.yumi.to" }
    public struct HarnessSettings: Sendable, Equatable {
        public var kind = HarnessKind.openclaw, agent = "yorozu", transport = Transport.native, gatewayURL = "ws://127.0.0.1:18789", devRepo = ""
        /// nil when `dev_repo` is empty; `~/` is expanded.
        public var devRepoURL: URL? { devRepo.isEmpty ? nil : URL(fileURLWithPath: (devRepo as NSString).expandingTildeInPath,isDirectory: true) }
    }
    /// A nil role or a missing executor is automatic (`ModelDefaults`).
    public struct Models: Sendable, Equatable {
        public var secretary, extraction, worker, review: String?; public var coding: [String:String] = [:]; public var rules = Rules()
        public init() {}
    }
    public struct Rules: Sendable, Equatable { public var minContextTokens = 32000, minOutputTokens = 16000 }
    public var general = General(), notifications = Notifications(), routing = Routing(), relay = Relay(), harness = HarnessSettings(), models = Models()
    public var mcpServers = MCPServers.defaults
    /// Keys Yorozu does not know, kept and written back as data.
    public var extra: [String:TOMLValue] = [:]
    /// Dotted keys the file set (`mcp_servers` for the whole list), for `SettingSource.file`.
    public internal(set) var fileKeys: Set<String> = []
    public init() {}

    public static func url(in root: URL) -> URL { root.appendingPathComponent("config.toml") }

    /// The validated file. A missing file is written with the defaults, plus the entries of a retired
    /// `mcp-servers.json` in the same folder.
    public static func load(_ url: URL) throws -> Config {
        if !FileManager.default.fileExists(atPath: url.path) {
            var fresh = Config()
            if let legacy = MCPServers.legacy(url.deletingLastPathComponent().appendingPathComponent("mcp-servers.json")) { fresh.mcpServers = legacy }
            try fresh.write(url,replace: false)
        }
        do { return try parse(try String(contentsOf: url,encoding: .utf8),file: url) }
        catch let error as ConfigError { throw error } catch { throw ConfigError(file: url.path,reason: error.localizedDescription) }
    }
    /// Read-modify-write: reads the file fresh, so an edit made since the last load is kept.
    @discardableResult public static func update(_ url: URL, _ change: (inout Config) throws -> Void) throws -> Config {
        lock.lock(); defer { lock.unlock() }
        var config = try load(url); try change(&config); try config.write(url); return try load(url)
    }
    private static let lock = NSLock()
    /// Atomic (temporary file, then rename), mode 0600; refuses an invalid config.
    public func write(_ url: URL, replace: Bool = true) throws {
        if let (key,reason) = problem() { throw ConfigError(file: url.path,key: key,reason: reason) }
        let folder = url.deletingLastPathComponent(), temp = folder.appendingPathComponent(".config.toml." + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: temp.path,contents: Data(toml().utf8),attributes: [.posixPermissions: 0o600]) else { throw ConfigError(file: url.path,reason: "could not write \(temp.path)") }
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
        field("general.send_key",\.general.sendKey,"\"smart\" or \"cmd-enter\" (⌘Enter sends)."),
        field("general.global_shortcut",\.general.globalShortcut,"Shortcut that brings up Yorozu; empty is off."),
        field("general.appearance",\.general.appearance,"\"system\", \"light\" or \"dark\"."),
        field("general.show_advanced",\.general.showAdvanced,"Show the Advanced tab in Settings."),
        field("notifications.enabled",\.notifications.enabled,"Post notifications."),
        field("notifications.destination",\.notifications.destination,"Where notifications appear: \"mac\" or \"phones\"."),
        field("routing.personal_knowledge",\.routing.personalKnowledge,"Where the user's personal notes live, named in the routing policy; empty drops that hint."),
        field("routing.self_topic",\.routing.selfTopic,"Topic that holds work on Yorozu itself."),
        field("relay.url",\.relay.url,"Relay for the iPhone app (ws:// or wss://). After a change every phone must pair again." + security),
        field("harness.kind",\.harness.kind,"Main harness: \"openclaw\"." + security),
        field("harness.agent",\.harness.agent,"Harness agent id Yorozu runs on." + security),
        field("harness.transport",\.harness.transport,"\"native\" (WebSocket client) or \"cli\" (openclaw CLI); applies after relaunch." + security),
        field("harness.gateway_url",\.harness.gatewayURL,"Gateway address, loopback only; applies after relaunch." + security),
        field("harness.dev_repo",\.harness.devRepo,"Repository for coding work (absolute path or ~/…); empty ends coding work with a notice." + security),
        field("models.secretary",\.models.secretary,"Secretary model (provider/model); leave out for automatic." + security),
        field("models.extraction",\.models.extraction,"Memory extraction model; leave out for automatic." + security),
        field("models.worker",\.models.worker,"Worker model; leave out for automatic." + security),
        field("models.review",\.models.review,"Stronger review model; leave out for automatic." + security),
        field("models.rules.min_context_tokens",\.models.rules.minContextTokens,"Smallest context window for the automatic secretary and extraction model."),
        field("models.rules.min_output_tokens",\.models.rules.minOutputTokens,"Smallest output cap for the automatic secretary and extraction model."),
    ]
    static let sections = [
        "general": "General.", "notifications": "Notifications.", "routing": "Routing hints for the secretary.", "relay": "iPhone relay.",
        "harness": "Harness connection.", "models": "Models per role; a missing role is chosen automatically from the harness's model metadata.",
        "models.coding": "Coding executor (claude, codex) = \"provider/model\"; a missing executor is automatic." + security,
        "models.rules": "Inputs of the automatic choice.",
        "mcp_servers": "MCP servers workers may use: [mcp_servers.<name>] with command (absolute path) and args; env is not supported." + security,
    ]
    /// Known keys and sections in file order.
    static let order: [String] = fields.flatMap { field in
        let parts = field.key.split(separator: ".")
        return (1..<parts.count).map { parts.prefix($0).joined(separator: ".") } + [field.key]
    }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }.flatMap { $0 == "models.rules" ? ["models.coding",$0] : [$0] } + ["mcp_servers"]

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
        if let coding = try take(&tree,["models","coding"],"models.coding") {
            guard case .table(let table) = coding else { throw fail("models.coding","expected a table of executor = \"provider/model\"") }
            for (executor,value) in table {
                guard case .string(let model) = value else { throw fail("models.coding.\(executor)","expected a string") }
                config.models.coding[executor] = model; config.fileKeys.insert("models.coding.\(executor)")
            }
        }
        if let servers = try take(&tree,["mcp_servers"],"mcp_servers") {
            guard case .table(let table) = servers else { throw fail("mcp_servers","expected [mcp_servers.<name>] tables") }
            var list: [String:MCPServer] = [:], rest: [String:TOMLValue] = [:]
            for (name,value) in table {
                let key = "mcp_servers.\(name)"
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
            config.mcpServers = list; config.fileKeys.insert("mcp_servers")
            if !rest.isEmpty { tree["mcp_servers"] = .table(rest) }
        }
        config.extra = tree
        if let (key,reason) = config.problem() { throw fail(key,reason) }
        return config
    }
    /// The first invalid value as (dotted key, reason).
    func problem() -> (String, String)? {
        let h = harness
        if h.agent.range(of: "^[A-Za-z0-9_-]{1,64}$",options: .regularExpression) == nil { return ("harness.agent","expected 1-64 letters, digits, - or _") }
        if !Self.isLoopbackGateway(h.gatewayURL) { return ("harness.gateway_url","expected a loopback ws:// or wss:// address with no path, such as ws://127.0.0.1:18789") }
        if !(h.devRepo.isEmpty || h.devRepo.hasPrefix("/") || h.devRepo.hasPrefix("~/")) { return ("harness.dev_repo","expected an absolute path, a ~/ path or \"\"") }
        if let url = URLComponents(string: relay.url), ["ws","wss"].contains(url.scheme ?? ""), !(url.host ?? "").isEmpty {} else { return ("relay.url","expected a ws:// or wss:// address") }
        for (key,model) in [("secretary",models.secretary),("extraction",models.extraction),("worker",models.worker),("review",models.review)] + models.coding.map({ ("coding.\($0.key)",$0.value) }) where model?.isEmpty == true { return ("models.\(key)","expected \"provider/model\"; leave the key out for automatic") }
        if models.rules.minContextTokens < 1 { return ("models.rules.min_context_tokens","expected a positive integer") }
        if models.rules.minOutputTokens < 1 { return ("models.rules.min_output_tokens","expected a positive integer") }
        if let name = MCPServers.invalid(mcpServers) { return ("mcp_servers.\(name)",MCPServers.rule) }
        return nil
    }
    /// The Gateway URL rule the CLI transport enforces: loopback host, ws or wss, no credentials, path, query or fragment.
    public static func isLoopbackGateway(_ target: String) -> Bool {
        guard let url = URLComponents(string: target) else { return false }
        return ["ws","wss"].contains(url.scheme ?? "") && ["127.0.0.1","::1","localhost"].contains(url.host ?? "") && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && ["","/"].contains(url.path)
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
        for (executor,model) in models.coding { put(&tree,["models","coding",executor],.string(model)) }
        for (name,server) in mcpServers {
            put(&tree,["mcp_servers",name,"command"],.string(server.command))
            if let args = server.args { put(&tree,["mcp_servers",name,"args"],.array(args.map { .string($0) })) }
        }
        var out = "# Yorozu settings. Yorozu rewrites this file in this layout: unknown keys are kept, added comments are not.\n# PROJECTX_* environment variables override these values.\n"
        func emit(_ table: [String:TOMLValue], _ path: [String]) {
            let dot = path.isEmpty ? "" : path.joined(separator: ".") + "."
            let rank = path.count == 2 && path[0] == "mcp_servers" ? ["command","args"] : Self.order.filter { $0.hasPrefix(dot) && !$0.dropFirst(dot.count).contains(".") }.map { String($0.dropFirst(dot.count)) }
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
        ("PROJECTX_TRANSPORT",["harness.transport"]), ("PROJECTX_GATEWAY_URL",["harness.gateway_url"]), ("PROJECTX_AGENT",["harness.agent"]),
        ("PROJECTX_DEV_REPO",["harness.dev_repo"]), ("PROJECTX_RELAY_URL",["relay.url"]),
        ("PROJECTX_SECRETARY_MODEL",["models.secretary","models.extraction"]), ("PROJECTX_MODEL",["models.worker"]), ("PROJECTX_REVIEW_MODEL",["models.review"]),
        ("PROJECTX_CLAUDE_MODEL",["models.coding.claude"]), ("PROJECTX_CODEX_MODEL",["models.coding.codex"]),
    ]
    /// The file's values with environment overrides applied.
    public private(set) var config: Config
    /// Dotted key → the variable that set it.
    public private(set) var environment: [String:String] = [:]
    public init(_ file: Config, environment env: [String:String] = ProcessInfo.processInfo.environment) throws {
        config = file
        for (name,keys) in Self.variables { guard let value = env[name] else { continue }
            for key in keys {
                if key.hasPrefix("models.coding.") { config.models.coding[String(key.dropFirst(14))] = value }
                else if let field = Config.fields.first(where: { $0.key == key }), !field.set(&config,.string(value)) { throw ProjectError.invalid("\(name): expected \(field.expected).") }
                environment[key] = name
            }
        }
        if let (key,reason) = config.problem() { throw ProjectError.invalid("\(environment[key] ?? key): \(reason).") }
    }
    public func source(_ key: String) -> SettingSource {
        environment[key] != nil ? .environment : config.fileKeys.contains(key) ? .file : key.hasPrefix("models.") && !key.hasPrefix("models.rules.") ? .automatic : .default
    }
    /// Per-role models from the harness's metadata; explicit choices (environment or file) win.
    public func models(_ available: [ModelInfo], primary: String?) -> ModelChoices { ModelDefaults.resolve(available,primary: primary,explicit: config.models) }
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
