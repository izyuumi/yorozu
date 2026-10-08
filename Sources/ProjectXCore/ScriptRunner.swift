import Foundation
import CryptoKit

/// How one job script run ended (#319).
public struct ScriptResult: Sendable {
    /// Exit status; nil when it never started or a signal ended it.
    public var exitCode: Int32?
    public var timedOut = false
    /// Why it never started.
    public var launchError: String?
    /// SHA-256 (hex) of stdout's hash followed by stderr's, so the two pipes' interleaving never changes it.
    public var outputSHA: String
    /// The full output, both streams in arrival order.
    public var log: URL
    /// Stdout, at most `ScriptRunner.stdoutCap` bytes (for `ai_when` regular expressions).
    public var stdout: String
    public var ok: Bool { exitCode == 0 && !timedOut && launchError == nil }
    /// A plain-language line for the sub-chat and notices.
    public var summary: String {
        if let launchError { return "Couldn't start the script: \(launchError)" }
        if timedOut { return "Timed out; stopped." }
        return exitCode.map { "Exit code \($0)." } ?? "Ended by a signal."
    }
}

/// Runs job scripts as child processes of the app, never through a harness: `/bin/zsh -f -c <script>` in
/// `<jobs root>/<id>/` (0700), with only the open-question-6 environment, in its own process group.
public final class ScriptRunner: @unchecked Sendable {
    /// `~/Yorozu/jobs` live; `<data root>/jobs` for `PROJECTX_DATA` and fixture runs.
    public let root: URL
    public static let stdoutCap = 1 << 20
    private let lock = NSLock()
    /// Running process groups by work id.
    private var groups: [String: pid_t] = [:]
    public init(root: URL) { self.root = root.standardizedFileURL }

    public func directory(job: String) throws -> URL {
        guard job.range(of: "^[a-z0-9][a-z0-9-]{0,39}$",options: .regularExpression) != nil else { throw ProjectError.invalid("Invalid job id.") }
        let dir = root.appendingPathComponent(job,isDirectory: true)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("runs",isDirectory: true),withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: dir.path)
        return dir
    }
    /// Exactly these variables; never `PROJECTX_*` or app secrets.
    static func environment(job: String, dir: URL) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        return ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": NSUserName(), "LANG": env["LANG"] ?? "en_US.UTF-8",
                "TZ": TimeZone.current.identifier, "YOROZU_JOB": job, "YOROZU_JOB_DIR": dir.path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    /// Runs the script to its end. `started` runs just before the spawn (the caller stamps the run ID there, so a quit
    /// from then on leaves the work uncertain, never re-queued); if it throws, nothing is spawned. `output` gets each
    /// chunk as ("output"|"error", text), in order, with no cut; the log keeps everything.
    public func run(work: String, job: String, script: String, timeout: Int, started: () async throws -> Void, output: @escaping @Sendable (String, String) async -> Void) async throws -> ScriptResult {
        let dir = try directory(job: job)
        let stamp = ISO8601DateFormatter.string(from: Date(),timeZone: .current,formatOptions: [.withFullDate,.withTime,.withColonSeparatorInTime]).replacingOccurrences(of: ":",with: "-")
        let log = dir.appendingPathComponent("runs/\(stamp)-\(work.prefix(8)).log")
        guard FileManager.default.createFile(atPath: log.path,contents: nil,attributes: [.posixPermissions: 0o600]), let logFile = try? FileHandle(forWritingTo: log) else { throw ProjectError.invalid("Couldn't create the run log \(log.path).") }
        defer { try? logFile.close() }
        try await started()

        var outPipe: [Int32] = [-1,-1], errPipe: [Int32] = [-1,-1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { return failed("pipe: \(String(cString: strerror(errno)))",log: log) }
        var actions: posix_spawn_file_actions_t? = nil, attr: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_addopen(&actions,0,"/dev/null",O_RDONLY,0)
        posix_spawn_file_actions_adddup2(&actions,outPipe[1],1); posix_spawn_file_actions_adddup2(&actions,errPipe[1],2)
        posix_spawn_file_actions_addchdir_np(&actions,dir.path)
        // Own process group (pgid = pid) so a timeout or quit ends everything it started; no inherited descriptors;
        // default signal handling and an empty mask.
        var none = sigset_t(), all = sigset_t(); sigemptyset(&none); sigfillset(&all)
        posix_spawnattr_setflags(&attr,Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr,0); posix_spawnattr_setsigmask(&attr,&none); posix_spawnattr_setsigdefault(&attr,&all)
        // -f: no ~/.zshenv, so the environment stays exactly this one.
        let args = ["/bin/zsh","-f","-c",script], env = Self.environment(job: job,dir: dir).map { "\($0.key)=\($0.value)" }
        var argv = args.map { strdup($0) } + [nil], envp = env.map { strdup($0) } + [nil]
        defer { for p in argv + envp { free(p) } }
        var spawnedPID: pid_t = 0
        let spawned = posix_spawn(&spawnedPID,"/bin/zsh",&actions,&attr,&argv,&envp)
        close(outPipe[1]); close(errPipe[1])
        guard spawned == 0 else { close(outPipe[0]); close(errPipe[0]); return failed(String(cString: strerror(spawned)),log: log) }
        let pid = spawnedPID
        lock.withLock { groups[work] = pid }
        defer { _ = lock.withLock { groups.removeValue(forKey: work) } }

        // Timeout: SIGTERM to the group, SIGKILL 5 s later.
        let timer = Task.detached { () -> Bool in
            guard (try? await Task.sleep(for: .seconds(max(1,timeout)))) != nil else { return false }
            Thread.detachNewThread { Self.terminate(group: pid,grace: 5) }; return true
        }
        // Both pipes feed one ordered stream: the log, the hashes and the sub-chat see the same order.
        let (chunks,sink) = AsyncStream<(Bool,Data)>.makeStream()
        let readers = [(outPipe[0],true),(errPipe[0],false)].map { fd,isOut in
            Thread.detachNewThreadWithResult { var buf = [UInt8](repeating: 0,count: 16384)
                while true { let n = read(fd,&buf,buf.count); if n <= 0 { break }; sink.yield((isOut,Data(buf[0..<n]))) }
                close(fd)
            }
        }
        let exit = Thread.detachNewThreadWithResult { () -> Int32 in var status: Int32 = 0; while waitpid(pid,&status,0) < 0 && errno == EINTR {}; return status }
        Task.detached { for r in readers { await r.value }; sink.finish() }
        var outHash = SHA256(), errHash = SHA256(), stdout = Data()
        var pending: [Bool: Data] = [:]
        for await (isOut,data) in chunks {
            try? logFile.write(contentsOf: data)
            if isOut { outHash.update(data: data); if stdout.count < Self.stdoutCap { stdout.append(data.prefix(Self.stdoutCap - stdout.count)) } } else { errHash.update(data: data) }
            // Whole UTF-8 sequences only: a chunk may end inside a character.
            let buffered = [UInt8]((pending[isOut] ?? Data()) + data), cut = Self.wholeCharacters(buffered)
            pending[isOut] = Data(buffered[cut...])
            if cut > 0 { await output(isOut ? "output" : "error",String(decoding: buffered[..<cut],as: UTF8.self)) }
        }
        for (isOut,rest) in pending where !rest.isEmpty { await output(isOut ? "output" : "error",String(decoding: rest,as: UTF8.self)) }
        let status = await exit.value
        timer.cancel(); let timedOut = await timer.value
        // The leader is gone; anything it left in the group goes too.
        Self.terminate(group: pid,grace: 0)
        let hex = { (d: SHA256.Digest) in d.map { String(format: "%02x",$0) }.joined() }
        let combined = SHA256.hash(data: Data((hex(outHash.finalize()) + hex(errHash.finalize())).utf8))
        let exited = status & 0x7f == 0
        return ScriptResult(exitCode: exited ? (status >> 8) & 0xff : nil,timedOut: timedOut,outputSHA: hex(combined),log: log,stdout: String(decoding: stdout,as: UTF8.self))
    }
    /// Length of the prefix that ends on a whole UTF-8 sequence (malformed tails count as whole).
    static func wholeCharacters(_ b: [UInt8]) -> Int {
        let floor = max(0,b.count - 4); var i = b.count - 1
        while i >= floor, b[i] & 0xC0 == 0x80 { i -= 1 }
        guard i >= floor else { return b.count }
        let need = b[i] >= 0xF0 ? 4 : b[i] >= 0xE0 ? 3 : b[i] >= 0xC0 ? 2 : 1
        return b.count - i >= need ? b.count : i
    }
    private func failed(_ reason: String,log: URL) -> ScriptResult {
        ScriptResult(exitCode: nil,launchError: reason,outputSHA: SHA256.hash(data: Data()).map { String(format: "%02x",$0) }.joined(),log: log,stdout: "")
    }
    /// Stop control: ends one work item's process group (SIGTERM, SIGKILL after 5 s). False when none is running.
    @discardableResult public func stop(work: String) -> Bool {
        guard let pid = lock.withLock({ groups[work] }) else { return false }
        Thread.detachNewThread { Self.terminate(group: pid,grace: 5) }; return true
    }
    public func running(work: String) -> Bool { lock.withLock { groups[work] != nil } }
    /// App quit: SIGTERM every group, wait up to 2 s, then SIGKILL what is left. Synchronous.
    public func terminateAll() {
        let pids = lock.withLock { Array(groups.values) }
        for pid in pids { killpg(pid,SIGTERM) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, pids.contains(where: { killpg($0,0) == 0 }) { usleep(50_000) }
        for pid in pids { killpg(pid,SIGKILL) }
    }
    /// SIGTERM to the group, then SIGKILL once `grace` seconds pass with any member left (at once for 0).
    static func terminate(group pid: pid_t, grace: Int) {
        if grace > 0 {
            guard killpg(pid,SIGTERM) == 0 else { return }
            let deadline = Date().addingTimeInterval(Double(grace))
            while Date() < deadline, killpg(pid,0) == 0 { usleep(100_000) }
        }
        killpg(pid,SIGKILL)
    }
}

private extension Thread {
    /// Runs blocking work on its own thread; the result arrives as a Task value.
    static func detachNewThreadWithResult<T: Sendable>(_ body: @escaping @Sendable () -> T) -> Task<T,Never> {
        let (stream,c) = AsyncStream<T>.makeStream()
        Thread.detachNewThread { c.yield(body()); c.finish() }
        return Task { for await v in stream { return v }; fatalError("thread ended without a result") }
    }
}

/// Lowercase hex SHA-256 of a string's UTF-8 bytes (script approval and spec hashes).
public func sha256Hex(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x",$0) }.joined() }
