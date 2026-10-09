import Foundation

/// A coding agent Yorozu runs for a worker (#351): data, `[coding_agents.<name>] command = [...]`. The worker calls it
/// with `Yorozu agent run`; the running app spawns `command` + the prompt (no shell) in the task's folder.
public struct CodingAgent: Sendable, Equatable {
    public var name: String
    /// The program and its arguments; the prompt is added as the last argument.
    public var command: [String]
    /// Seconds before the run's process group is stopped.
    public var timeout = CodingAgent.defaultTimeout
    /// The sign-in command to copy, for the built-ins.
    public var login: String?
    public static let defaultTimeout = 3600
    public init(name: String, command: [String], timeout: Int = CodingAgent.defaultTimeout, login: String? = nil) { self.name = name; self.command = command; self.timeout = timeout; self.login = login }
    /// Offered when their binary is found. Full access, like the owner's own runs: file access is unlimited by default
    /// (owner, 2026-10-09). Claude Code streams JSON so its progress reaches the sub-chat live (`CodingAgentHost.render`).
    public static let builtIn = [
        CodingAgent(name: "claude",command: ["claude","-p","--output-format","stream-json","--verbose","--permission-mode","bypassPermissions","--"],login: "claude auth login"),
        CodingAgent(name: "codex",command: ["codex","exec","--skip-git-repo-check","--sandbox","danger-full-access","--color","never","--"],login: "codex login"),
    ]
    /// Folders searched besides `PATH`: a Finder launch's `PATH` lacks them.
    static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init) + ["/opt/homebrew/bin","/usr/local/bin",home + "/.local/bin",home + "/.local/share/mise/shims"]
    }
    /// The program's absolute path: `command[0]` itself when absolute, else the first match on the search path; nil when not found.
    public var executable: String? {
        guard let program = command.first, !program.isEmpty else { return nil }
        let candidates = program.contains("/") ? [(program as NSString).expandingTildeInPath] : Self.searchPath.map { $0 + "/" + program }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// The folder each task works in (#351): `<workspace>/<topic label slug>-<topic id prefix>/`, made 0700 at first use and
/// derived from the topic, so nothing is stored. Attached sub-chats work in the topic they were attached to.
public enum Workspace {
    public static func folder(root: URL, topic: Topic) throws -> URL {
        let slug = topic.label.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }
            .joined().split(separator: "-").joined(separator: "-").prefix(32)
        let url = root.appendingPathComponent((slug.isEmpty ? "" : slug + "-") + topic.id.prefix(8),isDirectory: true)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        return url
    }
    /// Whether `path` is `root` or inside it, symlinks resolved.
    public static func contains(_ root: URL, _ path: URL) -> Bool {
        let r = root.resolvingSymlinksInPath().standardizedFileURL.path, p = path.resolvingSymlinksInPath().standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

/// The running app's side of `Yorozu agent run` (#351): a unix socket (0600, same user only) in the data root. Each
/// connection is one JSON request line and one JSON reply line. The app spawns the agent in the task's folder, streams its
/// output into the task's sub-chat as worker events, stops it at its timeout or when the task is stopped, and replies with
/// the final output.
public final class CodingAgentHost: @unchecked Sendable {
    public struct Request: Codable, Sendable {
        public var agent: String, task: String, dir: String?, prompt: String
        public init(agent: String, task: String, dir: String?, prompt: String) { self.agent = agent; self.task = task; self.dir = dir; self.prompt = prompt }
    }
    public struct Reply: Codable, Sendable {
        public var exitCode: Int32?, output: String, error: String?
        public init(exitCode: Int32? = nil, output: String = "", error: String? = nil) { self.exitCode = exitCode; self.output = output; self.error = error }
    }
    /// The running task's folder; throws unless the task is running.
    public typealias Folder = @Sendable (_ task: String) async throws -> URL
    /// Posts a sub-chat event of the task; throws once the task is stopped.
    public typealias Emit = @Sendable (_ event: WorkerEvent) async throws -> Void
    public static let promptCap = 100_000, outputCap = 20_000
    public let socket: URL
    private let settings: @Sendable () -> HarnessSettings, folder: Folder, emit: Emit
    private let runner: ScriptRunner
    private let lock = NSLock(); private var listener: Int32 = -1
    public init(socket: URL, settings: @escaping @Sendable () -> HarnessSettings, folder: @escaping Folder, emit: @escaping Emit) {
        self.socket = socket; self.settings = settings; self.folder = folder; self.emit = emit; runner = ScriptRunner(root: socket.deletingLastPathComponent())
    }

    public func start() throws {
        unlink(socket.path)
        let fd = Darwin.socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else { throw ProjectError.blocked("Couldn't open the coding-agent socket: " + String(cString: strerror(errno))) }
        guard var address = Self.address(socket.path) else { close(fd); throw ProjectError.blocked("The coding-agent socket path is too long: \(socket.path)") }
        let old = umask(0o177); defer { umask(old) } // created 0600
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self,capacity: 1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd,16) == 0 else { let e = errno; close(fd); throw ProjectError.blocked("Couldn't listen on \(socket.path): " + String(cString: strerror(e))) }
        lock.withLock { listener = fd }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd,nil,nil)
                if client < 0 { if errno == EINTR { continue }; return } // closed by stop()
                var uid = uid_t(), gid = gid_t()
                guard getpeereid(client,&uid,&gid) == 0, uid == getuid() else { close(client); continue }
                Task.detached { await self.serve(client) }
            }
        }
    }
    /// App quit: closes the socket and ends every running agent.
    public func stop() {
        lock.withLock { if listener >= 0 { close(listener); listener = -1 } }
        unlink(socket.path); runner.terminateAll()
    }
    static func address(_ path: String) -> sockaddr_un? {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8); guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes) }; return a
    }

    private func serve(_ client: Int32) async {
        defer { close(client) }
        guard let line = Self.readLine(client), let request = try? JSONDecoder().decode(Request.self,from: line) else { Self.write(client,Reply(error: "Invalid request.")); return }
        Self.write(client,await handle(request))
    }
    func handle(_ r: Request) async -> Reply {
        let s = settings(), agents = s.codingAgents.filter { $0.executable != nil }
        guard let agent = agents.first(where: { $0.name == r.agent }), let program = agent.executable else {
            return Reply(error: "No coding agent \"\(r.agent)\" is available here" + (agents.isEmpty ? "." : "; available: " + agents.map(\.name).joined(separator: ", ") + "."))
        }
        guard !r.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, r.prompt.utf8.count <= Self.promptCap else { return Reply(error: "The prompt must be 1-\(Self.promptCap) bytes.") }
        let home: URL
        do { home = try await folder(r.task) } catch { return Reply(error: error.localizedDescription) }
        let dir = r.dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath,isDirectory: true).standardizedFileURL } ?? home
        var isDir: ObjCBool = false
        guard dir.path.hasPrefix("/"), FileManager.default.fileExists(atPath: dir.path,isDirectory: &isDir), isDir.boolValue else { return Reply(error: "\(dir.path) is not a folder.") }
        // restrict (#351): coding agents run only inside the workspace.
        if s.restrict, let root = s.workspace, !Workspace.contains(root,dir) { return Reply(error: "File access is limited to the workspace \(root.path); \(dir.path) is outside it.") }

        let run = "agent-" + identifier(), task = r.task, emit = emit
        let post = { @Sendable (kind: String, body: String, n: Int) async throws in
            try await emit(WorkerEvent(id: "\(task):\(run):\(n)",taskID: task,kind: kind,body: body,created: Date().timeIntervalSince1970))
        }
        do { try await post("command","$ " + agent.command.joined(separator: " ") + " <prompt>  (in \(dir.path))",0) } catch { return Reply(error: error.localizedDescription) }
        let logs = home.appendingPathComponent(".yorozu",isDirectory: true)
        try? FileManager.default.createDirectory(at: logs,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter.string(from: Date(),timeZone: .current,formatOptions: [.withFullDate,.withTime,.withColonSeparatorInTime]).replacingOccurrences(of: ":",with: "-")
        let log = logs.appendingPathComponent("\(stamp)-\(agent.name).log")
        let lines = Lines(), runner = runner
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PROJECTX_") }
        // The program's own folder first: a Node tool (codex under mise) finds its node there.
        env["PATH"] = ([(program as NSString).deletingLastPathComponent] + CodingAgent.searchPath).joined(separator: ":")
        env["YOROZU_TASK_DIR"] = home.path
        let result: ScriptResult
        do {
            result = try await runner.spawn(work: run,argv: [program] + agent.command.dropFirst() + [r.prompt],dir: dir,environment: env,timeout: agent.timeout,log: log,started: {}) { kind,text,prior in
                for (k,body) in lines.take(kind,text) where !sensitive(prior + body) {
                    // A stopped task ends the run: emit throws once its work is suppressed.
                    do { try await post(k,body,lines.next()) } catch { _ = await runner.stop(work: run); return }
                }
            }
        } catch { return Reply(error: "Couldn't run \(agent.name): " + error.localizedDescription) }
        for (k,body) in lines.take("output","\n") { try? await post(k,body,lines.next()) }
        let output = utf8Excerpt(lines.result ?? lines.plain.trimmingCharacters(in: .whitespacesAndNewlines),bytes: Self.outputCap)
        let ended = result.launchError.map { "Couldn't start \(agent.name): \($0)" } ?? (result.timedOut ? "\(agent.name) ran past its \(agent.timeout)-second limit and was stopped." : result.ok ? "\(agent.name) finished." : "\(agent.name) ended: " + result.summary)
        try? await post(result.ok ? "lifecycle" : "error",ended + " Full output: " + log.path,lines.next())
        return Reply(exitCode: result.exitCode,output: output,error: result.ok ? nil : ended + " Full output: " + log.path)
    }

    /// One run's output turned into sub-chat rows: stdout by whole lines, Claude Code's stream-json rendered as its text
    /// and tool rows (its `result` is the final output), anything else as is. Called in order by one run.
    final class Lines: @unchecked Sendable {
        private var pending = "", n = 0
        var result: String?, plain = ""
        func next() -> Int { n += 1; return n }
        func take(_ kind: String, _ text: String) -> [(String,String)] {
            guard kind == "output" else { return [(kind,text)] }
            pending += text
            guard let cut = pending.lastIndex(of: "\n") else { return [] }
            let whole = pending[..<cut]; pending = String(pending[pending.index(after: cut)...])
            var rows: [(String,String)] = [], raw: [Substring] = []
            for line in whole.split(separator: "\n",omittingEmptySubsequences: false) {
                guard line.hasPrefix("{"), let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String:Any], let type = o["type"] as? String else { raw.append(line); continue }
                if type == "result" { result = o["result"] as? String ?? result; continue }
                guard type == "assistant" else { continue }
                for b in (o["message"] as? [String:Any])?["content"] as? [[String:Any]] ?? [] {
                    if b["type"] as? String == "text", let t = b["text"] as? String, !t.isEmpty { rows.append(("message",t)) }
                    if b["type"] as? String == "tool_use", let name = b["name"] as? String {
                        let input = b["input"] as? [String:Any] ?? [:]
                        if let c = input["command"] as? String { rows.append(("command","$ " + String(c.prefix(2000)))) }
                        else { rows.append(("tool",name + (((input["file_path"] ?? input["path"]) as? String).map { " " + $0 } ?? ""))) }
                    }
                }
            }
            let text = raw.joined(separator: "\n"); plain += text + "\n"
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rows.insert(("output",text),at: 0) }
            return rows
        }
    }

    // MARK: Client (`Yorozu agent run`)

    /// Sends one request to the app at `socket` and waits for the reply (the run's whole length).
    public static func call(socket: String, _ request: Request) throws -> Reply {
        guard var address = address(socket) else { throw ProjectError.invalid("Socket path too long: \(socket)") }
        let fd = Darwin.socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else { throw ProjectError.blocked(String(cString: strerror(errno))) }
        defer { close(fd) }
        let code = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self,capacity: 1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard code == 0 else { throw ProjectError.blocked("Yorozu isn't running (no socket at \(socket)): " + String(cString: strerror(errno))) }
        write(fd,request)
        guard let line = readLine(fd) else { throw ProjectError.uncertain("Yorozu closed the connection without a reply.") }
        return try JSONDecoder().decode(Reply.self,from: line)
    }
    static func write<T: Encodable>(_ fd: Int32, _ value: T) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { buf in var off = 0; while off < buf.count { let n = Darwin.write(fd,buf.baseAddress! + off,buf.count - off); if n <= 0 { if errno == EINTR { continue }; return }; off += n } }
    }
    /// One newline-terminated line, at most 1 MiB.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data(), buf = [UInt8](repeating: 0,count: 65536)
        while data.count < 1 << 20 {
            let n = read(fd,&buf,buf.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let i = data.firstIndex(of: 0x0A) { return data[..<i] }
        }
        return nil
    }
}
