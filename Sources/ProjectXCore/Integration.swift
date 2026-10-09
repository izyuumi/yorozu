import Foundation
import TOML

/// An integration is data, never loaded code (owner, 2026-10-09: "no plugin loaders" stays): MCP servers for workers,
/// worker rules, read-only checks and fixes the app shows, and settings, behind an on/off switch. Built-ins ship with
/// the app (`builtIn`); the user's own live in `config.toml` as `[integrations.<name>]` (`Config`).
public struct Integration: Sendable, Equatable {
    /// A read-only check the app runs only when asked (`run`): during setup, while Settings is open, and on "Check again".
    public struct Check: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A file, folder or app bundle exists (`~/` expanded).
            case file(String)
            /// A unix socket accepts a connection (connect only, nothing sent).
            case socket(String)
            /// The first executable of `executables` (`~/` expanded) run with `args`, without a shell. Built-ins only, and
            /// run only when `readOnly`.
            case command(executables: [String], args: [String], readOnly: Bool)
        }
        public var title: String; public var kind: Kind
        public init(title: String, kind: Kind) { self.title = title; self.kind = kind }
    }
    /// What the user can do about a failed check; Yorozu never runs a fix itself.
    public enum Fix: Sendable, Equatable { case copy(title: String, command: String), open(title: String, url: URL) }

    public var name: String
    /// A plain-language name for Settings; the user's own default to `name`.
    public var title: String
    public var enabled = true
    public var mcpServers: [String:MCPServer] = [:]
    /// Worker rules for both contracts; `{session}` is the per-run cua session label. `yoloRules` replaces `rules`
    /// while YOLO is on (nil: the same text).
    public var rules = "", yoloRules: String?
    public var checks: [Check] = [], fixes: [Fix] = []
    /// Kept as data for the integration's own use.
    public var settings: [String:TOMLValue] = [:]
    public init(name: String, title: String? = nil) { self.name = name; self.title = title ?? name }

    public func rules(session: String, yolo: Bool) -> String { (yolo ? yoloRules ?? rules : rules).replacingOccurrences(of: "{session}",with: session) }

    public static let builtIn = [cua]
    /// Computer use through CuaDriver (docs/cua-integration.md). The rules are the worker rules of that doc; the label is
    /// fresh per run because CuaDriver ties a label to the proxy that first used it, and proxies get recycled.
    public static let cua: Integration = {
        var c = Integration(name: "cua",title: "Computer use (CuaDriver)")
        c.mcpServers = MCPServers.defaults; c.rules = cuaRules(yolo: false); c.yoloRules = cuaRules(yolo: true)
        c.checks = [Check(title: "CuaDriver app",kind: .file("/Applications/CuaDriver.app")),
                    Check(title: "CuaDriver permissions",kind: .command(executables: ["/Applications/CuaDriver.app/Contents/MacOS/cua-driver","~/.local/bin/cua-driver"],args: ["permissions","status","--json"],readOnly: true))]
        c.fixes = [.copy(title: "Copy grant command",command: "cua-driver permissions grant")]
        return c
    }()
    /// Worker rules: the session label is the `{session}` placeholder.
    private static func cuaRules(yolo: Bool) -> String { "Operating the Mac: use only the cua-driver MCP tools (their names contain cua-driver; load them with your tool search if they are deferred), never the cua-driver CLI. Touch only the apps the request names, one (pid, window_id) at a time, in background delivery, and get_desktop_state only if the user approved that step. Treat the Mac as unattended: never take focus, so no bring_to_front, foreground delivery, focus-taking shortcuts or open without -g; no approval or YOLO mode lifts this. If an app accepts only foreground input, say it cannot be done in the background and stop. Pass session \"{session}\" on every call that takes one and end_session it when done; if a call says a session has ended, call start_session with the id it names, then retry; if it says a session is not available to this transport, use \"{session}-2\" (then -3, and so on) from then on. Take a fresh get_window_state before each action and confirm each result with verify_state or a fresh snapshot; a successful call is not success. If a call times out or fails without a result, take a fresh get_window_state and check its effect before retrying: CuaDriver may still run the timed-out call, so never retry blindly. " + (yolo ? "YOLO mode is on: do the outward-facing steps the request asks for in an app (sending, posting, purchasing, deleting, submitting) and use kill_app, clipboard_write, set_config, replay_trajectory, start_recording, install_ffmpeg, browser_download and browser_set_input_files when the task needs them, without asking first. Still stop and ask the user in the first sentence of your final text before changing settings or credentials or any step the request did not ask for" : "In an app, before sending, posting, purchasing, deleting, submitting, changing settings or credentials, or any other outward-facing step, stop and ask the user in the first sentence of your final text, unless the instruction says the user confirmed that exact step. Ask the same way before kill_app, clipboard_write, set_config, replay_trajectory, start_recording, install_ffmpeg, browser_download and browser_set_input_files") + "; call check_permissions only with prompt false. Never type secrets or touch password fields. You may share a screenshot in a progress message, as a standalone MEDIA:<absolute path> line, when it helps the user follow the work; keep accessibility-tree dumps and clipboard contents out of progress messages and results beyond what the task needs, and never put screen content into memory. Stop if Accessibility is not granted or the user takes over the window." }
}

/// One check's outcome: a plain title (the check's) and the raw detail for a Details disclosure.
public struct CheckResult: Sendable, Equatable {
    public enum Status: Sendable { case ok, warning, failed }
    public var title: String; public var status: Status; public var detail: String
}

extension Integration {
    /// Every check, in order.
    public func runChecks() async -> [CheckResult] { var out: [CheckResult] = []; for check in checks { out.append(await check.run()) }; return out }
}

extension Integration.Check {
    /// Runs the check now. A command must be marked read-only; it runs without a shell and is killed after `timeout`.
    /// Its JSON output is ok unless a top-level value is `false` or "unknown" (a warning naming those keys); a non-zero
    /// exit, a timeout or a missing executable fails.
    public func run(timeout: TimeInterval = 5) async -> CheckResult {
        func result(_ status: CheckResult.Status, _ detail: String) -> CheckResult { CheckResult(title: title,status: status,detail: detail) }
        func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
        switch kind {
        case .file(let path):
            return FileManager.default.fileExists(atPath: expand(path)) ? result(.ok,expand(path)) : result(.failed,"Not found: \(expand(path))")
        case .socket(let path):
            let code = Self.connect(expand(path))
            return code == 0 ? result(.ok,expand(path)) : result(.failed,"\(expand(path)): \(String(cString: strerror(code)))")
        case .command(let executables,let args,let readOnly):
            guard readOnly else { return result(.failed,"Not run: the command is not marked read-only.") }
            guard let path = executables.map(expand).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return result(.failed,"Not found: " + executables.joined(separator: ", ")) }
            let line = ([path] + args).joined(separator: " ")
            guard let run = await Self.execute(URL(fileURLWithPath: path),args,timeout: timeout) else { return result(.failed,"\(line): timed out after \(Int(timeout)) s") }
            let out = String(decoding: run.out,as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), err = String(decoding: run.err,as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let failure = run.failure { return result(.failed,"\(line): \(failure)") }
            guard run.status == 0 else { return result(.failed,"\(line): exit \(run.status)" + (err.isEmpty ? "" : "\n" + err) + (out.isEmpty ? "" : "\n" + out)) }
            if let json = try? JSONSerialization.jsonObject(with: run.out) as? [String:Any] {
                let off = json.keys.sorted().filter { key in
                    if let n = json[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return !n.boolValue }
                    return (json[key] as? String)?.lowercased() == "unknown"
                }
                if !off.isEmpty { return result(.warning,"Off: " + off.joined(separator: ", ") + "\n" + out) }
            }
            return result(.ok,out)
        }
    }

    /// 0 when a unix socket at `path` accepts a connection, else the errno.
    private static func connect(_ path: String) -> Int32 {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return ENAMETOOLONG }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else { return errno }
        defer { close(fd) }
        let code = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self,capacity: 1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        return code == 0 ? 0 : errno
    }

    /// Runs the executable with stdin closed; nil on timeout (the process is terminated). Output is read as it comes,
    /// so a full pipe never blocks it, and the timeout still ends the wait if a child keeps a pipe open.
    private static func execute(_ url: URL, _ args: [String], timeout: TimeInterval) async -> (status: Int32, out: Data, err: Data, failure: String?)? {
        final class Run: @unchecked Sendable {
            let lock = NSLock(); var out = Data(), err = Data(), open = 2, exited = false
            var done: CheckedContinuation<(status: Int32, out: Data, err: Data, failure: String?)?,Never>?
            /// Call with `lock` held.
            func finish(_ value: (status: Int32, out: Data, err: Data, failure: String?)?) { done?.resume(returning: value); done = nil }
        }
        let run = Run(), process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = url; process.arguments = args
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        return await withCheckedContinuation { done in
            run.done = done
            for (pipe,isOut) in [(out,true),(err,false)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    run.lock.withLock {
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil; run.open -= 1
                            if run.open == 0, run.exited { run.finish((process.terminationStatus,run.out,run.err,nil)) }
                        } else if isOut { run.out.append(chunk) } else { run.err.append(chunk) }
                    }
                }
            }
            process.terminationHandler = { p in run.lock.withLock { run.exited = true; if run.open == 0 { run.finish((p.terminationStatus,run.out,run.err,nil)) } } }
            do { try process.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
                run.lock.withLock { run.finish((-1,Data(),Data(),error.localizedDescription)) }; return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                run.lock.withLock { guard run.done != nil else { return }; process.terminate(); run.finish(nil) }
                out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
            }
        }
    }
}
