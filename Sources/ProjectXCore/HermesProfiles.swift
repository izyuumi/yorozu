import Foundation
import Security
import CryptoKit

/// Setup of Yorozu's two Hermes profiles (#318 H5), checked against Hermes Agent v0.21.6. `plan` lists every write so
/// the setup step engine can show it first; `apply` runs it, and only an explicit setup action calls `apply`.
/// Writes only `~/.hermes/profiles/yorozu-worker/` and `~/.hermes/profiles/yorozu-roles/`: keys through Hermes's own
/// `hermes -p <profile> config set`, `.env` and `SOUL.md` directly. Never runs Hermes's installer, `update`, `setup` or `claw`.
public enum HermesProfiles {
    public static let worker = "yorozu-worker", roles = "yorozu-roles", profiles: Set<String> = [worker, roles]
    public static let keychainService = "to.yumi.yorozu.hermes"
    /// #310's compaction threshold, about half of the usable window, when Settings has no window.
    public static let defaultThresholdTokens = 129_200
    static let workFolder = "work"
    static let soul = """
    You are the model behind Yorozu's roles. Yorozu is a personal assistant app on the user's Mac. It calls you for its \
    secretary role (routing a user message and writing short replies) and its extraction role (proposing memory notes \
    from a conversation). Each request names the role and the exact output format. Answer only in that format: no \
    greeting, no commentary and no extra text around it. You have no tools and no project files; work only from the request.

    """

    public struct Settings: Sendable, Equatable {
        /// `workspace`: `yorozu-worker`'s `terminal.cwd` (#351); each task's contract names its own folder inside it. Nil is the home folder.
        public var home: URL, workspace: URL?, usableWindow: Int?, mcpServers: [String:MCPServer]
        public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, workspace: URL? = nil, usableWindow: Int? = nil, mcpServers: [String:MCPServer] = MCPServers.defaults) {
            self.home = home; self.workspace = workspace; self.usableWindow = usableWindow; self.mcpServers = mcpServers
        }
        /// The live workspace: Hermes runs only in live mode, so an empty `[workspace] path` is `~/Yorozu/workspace`.
        public init(config: Config, usableWindow: Int? = nil) { self.init(workspace: config.workspace.url(dataRoot: FileManager.default.homeDirectoryForCurrentUser,isolated: false), usableWindow: usableWindow, mcpServers: config.effectiveMCPServers) }
    }

    public enum Step: Sendable, Equatable, CustomStringConvertible {
        /// `hermes -p default profile create <name> --no-alias --no-skills`, only when the folder is missing.
        case createProfile(String)
        /// `hermes -p <profile> config set [--force] <key> <value>`.
        case setConfig(profile: String, key: String, value: String, force: Bool = false)
        /// `API_SERVER_KEY` in the profile's `.env` (mode 0600, other lines kept): an existing key of 32+ characters is
        /// kept, otherwise a new one is generated. Mirrored to the Keychain either way.
        case writeAPIKey(profile: String)
        case writeSOUL(profile: String, text: String)
        /// An empty folder inside the profile (no project files).
        case makeFolder(profile: String, name: String)

        public var profile: String {
            switch self { case .createProfile(let p), .setConfig(let p,_,_,_), .writeAPIKey(let p), .writeSOUL(let p,_), .makeFolder(let p,_): p }
        }
        public var description: String {
            switch self {
            case .createProfile(let p): "Create Hermes profile \(p): hermes profile create \(p) --no-alias --no-skills"
            case let .setConfig(p,key,value,force): "hermes -p \(p) config set \(force ? "--force " : "")\(key) '\(value)'"
            case .writeAPIKey(let p): "Write API_SERVER_KEY to ~/.hermes/profiles/\(p)/.env (mode 0600, other lines kept) and the Keychain item \(keychainService) / \(p)"
            case let .writeSOUL(p,_): "Write ~/.hermes/profiles/\(p)/SOUL.md (Yorozu's role identity)"
            case let .makeFolder(p,name): "Create the empty working folder ~/.hermes/profiles/\(p)/\(name)"
            }
        }
    }

    /// Every write setup would make, in order.
    public static func plan(_ settings: Settings) throws -> [Step] {
        let window = settings.usableWindow.map { $0 / 2 } ?? defaultThresholdTokens
        var steps: [Step] = []
        for profile in [worker, roles] {
            if !FileManager.default.fileExists(atPath: profileDir(profile, settings.home).path) { steps.append(.createProfile(profile)) }
            steps.append(.writeAPIKey(profile: profile))
            steps += [("memory.memory_enabled","false"), ("memory.user_profile_enabled","false"), ("auxiliary.background_review.enabled","false"),
                      ("curator.enabled","false"), ("agent.disabled_toolsets",#"["cronjob", "skills"]"#), ("auth.adopt_external_logins","false")]
                .map { Step.setConfig(profile: profile, key: $0.0, value: $0.1) }
        }
        let cwd = (settings.workspace ?? settings.home).standardizedFileURL.path
        steps += [Step.setConfig(profile: worker, key: "approvals.mode", value: "off"), .setConfig(profile: worker, key: "terminal.cwd", value: cwd),
                  .setConfig(profile: worker, key: "compression.threshold_tokens", value: String(window)), try projectMCP(servers: settings.mcpServers)]
        steps += [Step.makeFolder(profile: roles, name: workFolder), .setConfig(profile: roles, key: "terminal.cwd", value: profileDir(roles, settings.home).appendingPathComponent(workFolder).path),
                  .setConfig(profile: roles, key: "platform_toolsets.api_server", value: #"["no_mcp"]"#), .writeSOUL(profile: roles, text: soul)]
        return steps
    }

    /// The plan's writes not yet in place, read-only, each with its change line (what is on disk → what the write sets):
    /// the harness step's diff and digest, and the staleness check. Empty once Yorozu's profiles are as planned.
    public static func pending(_ settings: Settings) throws -> [(step: Step, change: OpenClawPlan.Change)] {
        var configs: [String: [String:Any]?] = [:]
        func onDisk(_ p: String, _ key: String) -> String? {
            if configs[p] == nil { configs[p] = .some(yamlTree((try? String(contentsOf: profileDir(p, settings.home).appendingPathComponent("config.yaml"), encoding: .utf8)) ?? "")) }
            guard let tree = configs[p]! else { return "(config.yaml not readable)" }
            var node: Any? = tree
            for part in key.split(separator: ".") { node = (node as? [String:Any])?[String(part)] }
            return node.map(canonical)
        }
        return try plan(settings).compactMap { step in
            let dir = profileDir(step.profile, settings.home), change: OpenClawPlan.Change?
            switch step {
            case .createProfile(let p): change = .init(path: "profile \(p)", old: nil, new: "hermes profile create \(p) --no-alias --no-skills")
            case let .setConfig(p,key,value,_):
                let parsed = value.hasPrefix("[") || value.hasPrefix("{") ? (try? JSONSerialization.jsonObject(with: Data(value.utf8))) ?? value : value
                let old = onDisk(p, key), new = canonical(parsed)
                change = old == new ? nil : .init(path: "\(p): \(key)", old: old, new: new)
            case .writeAPIKey(let p):
                let key = ((try? String(contentsOf: dir.appendingPathComponent(".env"), encoding: .utf8)) ?? "").components(separatedBy: .newlines).compactMap(apiKeyValue).last
                change = key.map { $0.count >= 32 && keychainMatches(p, key: $0) } == true ? nil
                    : .init(path: "\(p)/.env: API_SERVER_KEY", old: key.map { $0.count < 32 ? "(shorter than 32 characters)" : "(the Keychain holds another key or none)" }, new: "(a key, also saved in the Keychain)")
            case let .writeSOUL(p,text):
                let old = try? String(contentsOf: dir.appendingPathComponent("SOUL.md"), encoding: .utf8)
                change = old == text ? nil : .init(path: "\(p)/SOUL.md", old: old.map { _ in "(other text)" }, new: "(Yorozu's role identity)")
            case let .makeFolder(p,name):
                var folder: ObjCBool = false
                change = FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &folder) && folder.boolValue ? nil : .init(path: "\(p)/\(name)", old: nil, new: "(empty folder)")
            }
            return change.map { (step, $0) }
        }
    }

    /// Rewrites `mcp_servers` in `yorozu-worker` (Hermes reloads it within about a minute). No server gets `trust`, so
    /// none is `untrusted`. `--force` because `config set` refuses to replace an existing mapping section without it.
    public static func projectMCP(servers: [String:MCPServer]) throws -> Step {
        if let name = MCPServers.invalid(servers) { throw ProjectError.invalid("MCP server \(name) \(MCPServers.rule).") }
        let table = servers.mapValues { server -> [String:Any] in var entry: [String:Any] = ["command": server.command]; if let args = server.args { entry["args"] = args }; return entry }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: table, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return .setConfig(profile: worker, key: "mcp_servers", value: json, force: true)
    }

    public static func apply(_ steps: [Step], home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws {
        let launcher = try hermesLauncher(home)
        for step in steps {
            let dir = try profileDir(checked: step.profile, home)
            switch step {
            case .createProfile(let p):
                guard !FileManager.default.fileExists(atPath: dir.path) else { continue }
                try await run(launcher, ["-p","default","profile","create",p,"--no-alias","--no-skills"], home)
            case let .setConfig(p,key,value,force):
                try await run(launcher, ["-p",p,"config","set"] + (force ? ["--force"] : []) + [key,value], home)
            case .writeAPIKey(let p):
                let env = dir.appendingPathComponent(".env")
                // Only a missing file starts empty; any other read error would drop the profile's other settings.
                let existing: String
                do { existing = try String(contentsOf: try regularFile(env), encoding: .utf8) } catch let e as CocoaError where e.code == .fileReadNoSuchFile { existing = "" }
                var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }
                let old = lines.compactMap(apiKeyValue).last
                let key = try old.flatMap { $0.count >= 32 ? $0 : nil } ?? generateKey()
                lines.removeAll { apiKeyValue($0) != nil }
                lines.append("API_SERVER_KEY=\(key)")
                try write(lines.joined(separator: "\n") + "\n", to: env, mode: 0o600)
                try saveKeychain(account: p, key: key)
            case let .writeSOUL(_,text):
                try write(text, to: dir.appendingPathComponent("SOUL.md"), mode: 0o644)
            case let .makeFolder(_,name):
                let folder = dir.appendingPathComponent(name)
                guard !isSymlink(folder) else { throw ProjectError.blocked("\(folder.path) is a symbolic link; Yorozu writes only real folders in its Hermes profiles.") }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
    }

    /// Names of the MCP toolsets (`mcp-<name>`) that `GET /v1/toolsets` reports as enabled, or [] when the call fails.
    /// v0.21.6's handler lists the built-in configurable and plugin toolsets only, so an empty answer is "unconfirmed".
    public static func confirmMCP(baseURL: URL, key: String) async -> [String] {
        guard let host = baseURL.host, ["127.0.0.1","localhost","::1"].contains(host) else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/toolsets"), timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let list = (try? JSONSerialization.jsonObject(with: data) as? [String:Any])?["data"] as? [[String:Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String, name.hasPrefix("mcp-"), entry["enabled"] as? Bool ?? true else { return nil }
            return String(name.dropFirst(4))
        }.sorted()
    }

    /// Open question 1, read-only: Hermes serves `/p/<profile>/` only when the default profile's API server is on. v0.21.6
    /// turns it on from a usable `API_SERVER_KEY` (16+ characters) alone and ignores `API_SERVER_ENABLED` (gateway/config_env.py).
    /// Returns nil when it is on, else the step for the user. Never edits the default profile.
    public static func defaultProfileAPIServerStep(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let root = home.appendingPathComponent(".hermes")
        let env = (try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
        let yaml = (try? String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        let hasKey = env.components(separatedBy: .newlines).contains { (envValue($0, "API_SERVER_KEY") ?? "").count >= 16 } || (yamlAPIServer(yaml, "key") ?? "").count >= 16
        if hasKey { return nil }
        return """
        Turn on the API server in your default Hermes profile, so Hermes can serve Yorozu's profiles. Run in Terminal:

        hermes -p default config set API_SERVER_KEY "$(openssl rand -hex 32)"
        hermes -p default gateway restart

        Yorozu does not change your default profile itself.
        """
    }

    // MARK: - Paths and files

    static func profileDir(_ name: String, _ home: URL) -> URL { home.appendingPathComponent(".hermes/profiles/\(name)", isDirectory: true) }
    /// The profile folder, refusing any other profile and a symlinked `profiles/` or profile folder.
    static func profileDir(checked name: String, _ home: URL) throws -> URL {
        guard profiles.contains(name) else { throw ProjectError.blocked("Yorozu writes only its own Hermes profiles; \(name) was refused.") }
        let dir = profileDir(name, home)
        for url in [dir.deletingLastPathComponent(), dir] where isSymlink(url) { throw ProjectError.blocked("\(url.path) is a symbolic link; Yorozu does not write through it.") }
        return dir
    }
    static func isSymlink(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink }
    static func regularFile(_ url: URL) throws -> URL {
        if isSymlink(url) { throw ProjectError.blocked("\(url.path) is a symbolic link; Yorozu does not write through it.") }
        return url
    }
    /// Atomic replace: a new temp file created with `mode` (never wider, even briefly) in the same folder, then rename.
    static func write(_ text: String, to url: URL, mode: Int) throws {
        _ = try regularFile(url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).yorozu-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw ProjectError.blocked("Could not write \(url.path) (errno \(errno)).") }
        do { let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); try handle.write(contentsOf: Data(text.utf8)); try handle.close() }
        catch { try? FileManager.default.removeItem(at: temp); throw ProjectError.blocked("Could not write \(url.path).") }
        guard rename(temp.path, url.path) == 0 else { try? FileManager.default.removeItem(at: temp); throw ProjectError.blocked("Could not replace \(url.path) (errno \(errno)).") }
    }

    // MARK: - .env and YAML reading (no YAML library: line scans of the few keys needed)

    static func envValue(_ line: String, _ name: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("export ") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard text.hasPrefix(name), let eq = text.firstIndex(of: "="), text[..<eq].trimmingCharacters(in: .whitespaces) == name else { return nil }
        return unquote(String(text[text.index(after: eq)...]))
    }
    static func apiKeyValue(_ line: String) -> String? { envValue(line, "API_SERVER_KEY") }
    static func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { return String(value.dropFirst().dropLast()) }
        return value.components(separatedBy: " #").first!.trimmingCharacters(in: .whitespaces)
    }
    /// `field` of an `api_server:` block under `gateway:`, `gateway.platforms:` or top-level `platforms:` (block style only).
    static func yamlAPIServer(_ yaml: String, _ field: String) -> String? {
        var stack: [(indent: Int, key: String)] = [], found: String?
        for raw in yaml.components(separatedBy: .newlines) {
            let content = raw.components(separatedBy: " #").first!, trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let indent = content.prefix { $0 == " " }.count, key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            stack.removeAll { $0.indent >= indent }
            let path = stack.map(\.key)
            if key == field, ["gateway.api_server","gateway.platforms.api_server","platforms.api_server"].contains(path.joined(separator: ".")) {
                found = unquote(String(trimmed[trimmed.index(after: colon)...]))
            }
            stack.append((indent, key))
        }
        return found
    }

    /// A profile's `config.yaml` as Hermes 0.21.6 writes it (ruamel round-trip, `utils.atomic_roundtrip_yaml_save`: block
    /// style, 2-space mappings, `- ` items under their key, quotes and comments kept): mappings, sequences, `[]`, `{}`, flow
    /// lists of scalars, quoted and folded scalars, comments. Every scalar is a string. Nil for anything else, such as a
    /// line it can't classify, an unbalanced quote, a tab in the indent or a duplicate key; every key then counts as changed.
    static func yamlTree(_ text: String) -> [String:Any]? {
        let lines = text.components(separatedBy: .newlines).filter { let t = $0.trimmingCharacters(in: .whitespaces); return !t.isEmpty && !t.hasPrefix("#") && t != "---" }
        if lines.contains(where: { $0.prefix { $0 == " " || $0 == "\t" }.contains("\t") }) { return nil }
        var i = 0, bad = false
        func indent(_ n: Int) -> Int { lines[n].prefix { $0 == " " }.count }
        func item(_ n: Int, _ at: Int) -> Bool { let t = lines[n].dropFirst(at); return t == "-" || t.hasPrefix("- ") }
        /// A scalar and its folded continuation lines (deeper than `at`).
        func scalar(_ first: String, _ at: Int) -> Any {
            var text = first
            while i < lines.count, indent(i) > at { text += " " + lines[i].trimmingCharacters(in: .whitespaces); i += 1 }
            if let q = text.first, q == "'" || q == "\"" {
                var body = "", rest = Substring(text.dropFirst()), closed = false
                while let c = rest.popFirst() {
                    if c == q, q == "'", rest.first == "'" { body.append(rest.removeFirst()); continue }
                    if c == q { closed = true; break }
                    if c == "\\", q == "\"", let next = rest.popFirst() { body.append(next); continue }
                    body.append(c)
                }
                let after = rest.trimmingCharacters(in: .whitespaces)
                if !closed || !(after.isEmpty || after.hasPrefix("#")) { bad = true }
                return body
            }
            let plain = text.components(separatedBy: " #").first!.trimmingCharacters(in: .whitespaces)
            if plain == "[]" { return [Any]() }
            if plain == "{}" { return [String:Any]() }
            guard !plain.hasPrefix("{") else { bad = true; return plain }
            if plain.hasPrefix("[") {
                let inner = plain.dropFirst().dropLast()
                guard plain.hasSuffix("]"), !inner.contains(where: { "[]{}".contains($0) }) else { bad = true; return plain }
                return inner.split(separator: ",").map { unquote(String($0)) }
            }
            return plain
        }
        func node(_ at: Int) -> Any {
            if item(i, at) {
                var list: [Any] = []
                while i < lines.count, indent(i) == at, item(i, at) {
                    let rest = lines[i].dropFirst(at + 1).trimmingCharacters(in: .whitespaces); i += 1
                    list.append(rest.isEmpty ? (i < lines.count && indent(i) > at ? node(indent(i)) : "") : scalar(rest, at))
                }
                return list
            }
            var map: [String:Any] = [:]
            while i < lines.count, indent(i) == at, !item(i, at) {
                let line = String(lines[i].dropFirst(at)); i += 1
                guard let colon = line.range(of: ": ")?.lowerBound ?? (line.hasSuffix(":") ? line.index(before: line.endIndex) : nil) else { bad = true; continue }
                let key = unquote(String(line[..<colon])), rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if map[key] != nil { bad = true }
                if !rest.isEmpty, !rest.hasPrefix("#") { map[key] = scalar(rest, at) }
                else if i < lines.count, indent(i) > at || (indent(i) == at && item(i, at)) { map[key] = node(indent(i)) }
                else { map[key] = "" }
            }
            return map
        }
        var root: [String:Any] = [:]
        while i < lines.count, !bad {
            guard indent(i) == 0, let m = node(0) as? [String:Any] else { return nil }
            for (k, v) in m { if root[k] != nil { bad = true }; root[k] = v }
        }
        return bad ? nil : root
    }
    /// A value as comparable JSON text: scalars as strings (so a quoted "[...]" never equals a list), lists and mappings
    /// as sorted JSON of those strings.
    static func canonical(_ value: Any) -> String {
        func plain(_ v: Any) -> Any {
            switch v {
            case let s as String: s
            case let n as NSNumber: CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            case let a as [Any]: a.map(plain)
            case let d as [String:Any]: d.mapValues(plain)
            default: "\(v)"
            }
        }
        let p = plain(value)
        return (try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "\(p)"
    }

    // MARK: - Key and Keychain

    /// A non-secret fingerprint of a key, kept in the Keychain item's `kSecAttrGeneric`: 8 bytes of its SHA-256.
    static func fingerprint(_ key: String) -> Data { Data(SHA256.hash(data: Data(key.utf8)).prefix(8)) }
    /// Whether the Keychain item holds `key`, judged by its fingerprint attribute; reads no secret, so no prompt. An item
    /// without the attribute does not match.
    static func keychainMatches(_ account: String, key: String) -> Bool {
        var found: CFTypeRef?
        let query: [String:Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: account,
                                   kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return false }
        return (found as? [String:Any])?[kSecAttrGeneric as String] as? Data == fingerprint(key)
    }

    /// 32 random bytes as base64url: 43 characters.
    static func generateKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ProjectError.blocked("Could not generate a Hermes API key.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func saveKeychain(account: String, key: String) throws {
        let query: [String:Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: account]
        let update: [String:Any] = [kSecValueData as String: Data(key.utf8), kSecAttrGeneric as String: fingerprint(key), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ProjectError.blocked("Could not save the Hermes API key for \(account) in the Keychain. Unlock the login Keychain and retry setup.") }
    }

    // MARK: - Hermes CLI

    /// The `hermes` launcher: `~/.local/bin/hermes` (Hermes's installer), then PATH and the Homebrew folders.
    static func hermesLauncher(_ home: URL) throws -> URL {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = [home.appendingPathComponent(".local/bin").path] + path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin","/usr/local/bin"]
        guard let found = dirs.map({ URL(fileURLWithPath: $0).appendingPathComponent("hermes") }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ProjectError.blocked("Hermes is not installed (no hermes launcher in ~/.local/bin or on PATH). Install Hermes Agent first; Yorozu does not install it.")
        }
        return found
    }
    /// Only `profile create` and `config set` on Yorozu's profiles may run.
    static func allowed(_ args: [String]) -> Bool {
        if args.count == 7, args[..<4] == ["-p","default","profile","create"], profiles.contains(args[4]), args[5...] == ["--no-alias","--no-skills"] { return true }
        return [6,7].contains(args.count) && args[0] == "-p" && profiles.contains(args[1]) && args[2...3] == ["config","set"] && (args.count == 6 || args[4] == "--force")
    }
    static func run(_ launcher: URL, _ args: [String], _ home: URL) async throws {
        guard allowed(args) else { throw ProjectError.blocked("Refused Hermes command: hermes \(args.prefix(4).joined(separator: " ")).") }
        try await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = launcher; process.arguments = args
            var env = ProcessInfo.processInfo.environment
            // `-p` resolves profiles under HERMES_HOME (plus HERMES_DATA_DIR_SUFFIX) when set; pin ~/.hermes.
            env["HERMES_HOME"] = nil; env["HERMES_DATA_DIR_SUFFIX"] = nil
            env["HOME"] = home.path
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
            process.environment = env
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
            do { try process.run() } catch { throw ProjectError.blocked("Could not start \(launcher.path).") }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: deadline)
            defer { deadline.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let text = String(decoding: data.suffix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ProjectError.blocked("hermes \(args.prefix(5).joined(separator: " ")) failed (exit \(process.terminationStatus)): \(text)")
            }
        }.value
    }
}
