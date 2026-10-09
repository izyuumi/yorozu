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
    /// Output bytes per run that reach the sub-chat; the log keeps the rest.
    public static let chatCap = 2 << 20
    /// Characters of a stream's preceding text handed to `output` for secret screening across chunk boundaries.
    static let screenWindow = 256
    private let lock = NSLock()
    /// Running process groups by work id, until the leader exits; then the group is killed and the leader reaped.
    private var groups: [String: pid_t] = [:]
    /// Set by `terminateAll`: runs end with `CancellationError`, never as failed.
    private var quitting = false
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
    /// chunk as ("output"|"error"|"lifecycle", text, the stream's preceding text for screening), in order, with no cut,
    /// up to `chatCap` bytes; the log keeps everything. Throws `CancellationError` when the app quits meanwhile.
    public func run(work: String, job: String, script: String, timeout: Int, started: () async throws -> Void, output: @escaping @Sendable (String, String, String) async -> Void) async throws -> ScriptResult {
        let dir = try directory(job: job)
        let stamp = ISO8601DateFormatter.string(from: Date(),timeZone: .current,formatOptions: [.withFullDate,.withTime,.withColonSeparatorInTime]).replacingOccurrences(of: ":",with: "-")
        let log = dir.appendingPathComponent("runs/\(stamp)-\(work.prefix(8)).log")
        // -f: no ~/.zshenv, so the environment stays exactly this one.
        return try await spawn(work: work,argv: ["/bin/zsh","-f","-c",script],dir: dir,environment: Self.environment(job: job,dir: dir),timeout: timeout,log: log,started: started,output: output)
    }
    /// `run` for any program: `argv[0]` is an absolute path, run without a shell in `dir` with exactly `environment`, its
    /// output logged to `log` (created 0600). Coding agents (#351) run through this too, keyed by their own run id.
    public func spawn(work: String, argv args: [String], dir: URL, environment: [String:String], timeout: Int, log: URL, started: () async throws -> Void, output: @escaping @Sendable (String, String, String) async -> Void) async throws -> ScriptResult {
        guard FileManager.default.createFile(atPath: log.path,contents: nil,attributes: [.posixPermissions: 0o600]), let logFile = try? FileHandle(forWritingTo: log) else { throw ProjectError.invalid("Couldn't create the run log \(log.path).") }
        defer { try? logFile.close() }
        try await started()

        var outPipe: [Int32] = [-1,-1], errPipe: [Int32] = [-1,-1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { let e = errno; for fd in outPipe + errPipe where fd >= 0 { close(fd) }; return failed("pipe: \(String(cString: strerror(e)))",log: log) }
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
        let env = environment.map { "\($0.key)=\($0.value)" }
        var argv = args.map { strdup($0) } + [nil], envp = env.map { strdup($0) } + [nil]
        defer { for p in argv + envp { free(p) } }
        var spawnedPID: pid_t = 0
        let spawned = posix_spawn(&spawnedPID,args[0],&actions,&attr,&argv,&envp)
        close(outPipe[1]); close(errPipe[1])
        guard spawned == 0 else { close(outPipe[0]); close(errPipe[0]); return failed(String(cString: strerror(spawned)),log: log) }
        let pid = spawnedPID
        lock.withLock { groups[work] = pid; if quitting { killpg(pid,SIGKILL) } }

        // The leader's exit ends the run, not the pipes' end: a child that keeps them open can't hold it. The leader stays
        // a zombie until reaped, so its pid (the group id) can't be reused while the group is killed.
        let exit = Thread.detachNewThreadWithResult { () -> (status: Int32,at: Date) in
            var info = siginfo_t()
            while waitid(P_PID,id_t(pid),&info,WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            let at = Date()
            self.lock.withLock { _ = killpg(pid,SIGKILL); self.groups[work] = nil }
            var status: Int32 = 0; while waitpid(pid,&status,0) < 0 && errno == EINTR {}
            return (status,at)
        }
        // Timeout: SIGTERM to the group, SIGKILL 5 s later; it counts only when it fired before the leader exited.
        let timer = Task.detached { () -> Date? in
            guard (try? await Task.sleep(for: .seconds(max(1,timeout)))) != nil else { return nil }
            Thread.detachNewThread { self.terminate(work: work,pid: pid,grace: 5) }; return Date()
        }
        // Both pipes feed one ordered stream: the log, the hashes and the sub-chat see the same order. Only the chat part
        // is buffered, so the buffer stays under `chatCap` plus a chunk.
        let sinks = RunOutput(log: logFile)
        let (chunks,sink) = AsyncStream<(String,Data)>.makeStream()
        let readers = [(outPipe[0],true),(errPipe[0],false)].map { fd,isOut in
            Thread.detachNewThreadWithResult { var buf = [UInt8](repeating: 0,count: 16384)
                while true { let n = read(fd,&buf,buf.count); if n <= 0 { break }; for c in sinks.take(Data(buf[0..<n]),isOut: isOut) { sink.yield(c) } }
                close(fd)
            }
        }
        Task.detached { for r in readers { await r.value }; sink.finish() }
        // Once the leader is gone (and its group killed), the readers get 2 s to drain; a detached child still holding a
        // pipe is abandoned to the log.
        Task.detached { _ = await exit.value; timer.cancel(); try? await Task.sleep(for: .seconds(2)); sink.finish() }
        var pending: [String: Data] = [:], tails: [String: String] = [:]
        for await (kind,data) in chunks {
            // Whole UTF-8 sequences only: a chunk may end inside a character.
            let buffered = [UInt8]((pending[kind] ?? Data()) + data), cut = Self.wholeCharacters(buffered)
            pending[kind] = Data(buffered[cut...])
            guard cut > 0 else { continue }
            let text = String(decoding: buffered[..<cut],as: UTF8.self), prior = tails[kind] ?? ""
            tails[kind] = String((prior + text).suffix(Self.screenWindow))
            await output(kind,text,prior)
        }
        for (kind,rest) in pending where !rest.isEmpty { await output(kind,String(decoding: rest,as: UTF8.self),tails[kind] ?? "") }
        let (status,exitedAt) = await exit.value
        timer.cancel(); let fired = await timer.value
        let (outHex,errHex,stdout) = sinks.close()
        if lock.withLock({ quitting }) { throw CancellationError() }
        let combined = SHA256.hash(data: Data((outHex + errHex).utf8))
        let exited = status & 0x7f == 0
        return ScriptResult(exitCode: exited ? (status >> 8) & 0xff : nil,timedOut: fired.map { $0 <= exitedAt } ?? false,outputSHA: Self.hex(combined),log: log,stdout: String(decoding: stdout,as: UTF8.self))
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
        ScriptResult(exitCode: nil,launchError: reason,outputSHA: Self.hex(SHA256.hash(data: Data())),log: log,stdout: "")
    }
    static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x",$0) }.joined() }
    /// Stop control: ends one work item's process group (SIGTERM, SIGKILL after 5 s) and returns once its leader is
    /// gone; true when nothing of it is left running.
    public func stop(work: String) async -> Bool {
        guard let pid = lock.withLock({ groups[work] }) else { return true }
        await Thread.detachNewThreadWithResult { self.terminate(work: work,pid: pid,grace: 5) }.value
        for _ in 0..<20 where running(work: work) { try? await Task.sleep(for: .milliseconds(100)) }
        return !running(work: work)
    }
    public func running(work: String) -> Bool { lock.withLock { groups[work] != nil } }
    /// App quit: SIGTERM every group, wait up to 2 s, then SIGKILL what is left. Synchronous. Runs then end with
    /// `CancellationError`, so their work stays stamped and the next launch reports it interrupted.
    public func terminateAll() {
        lock.withLock { quitting = true; for pid in groups.values { killpg(pid,SIGTERM) } }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, lock.withLock({ !groups.isEmpty }) { usleep(50_000) }
        lock.withLock { for pid in groups.values { killpg(pid,SIGKILL) } }
    }
    /// SIGTERM to the group, then SIGKILL once `grace` seconds pass with its leader left. Only while `pid` is still this
    /// run's unreaped leader, so a reused pid is never signalled.
    func terminate(work: String, pid: pid_t, grace: Int) {
        let signal = { (sig: Int32) in self.lock.withLock { self.groups[work] == pid && killpg(pid,sig) == 0 } }
        guard signal(SIGTERM) else { return }
        let deadline = Date().addingTimeInterval(Double(grace))
        while Date() < deadline, signal(0) { usleep(100_000) }
        _ = signal(SIGKILL)
    }
}

/// One run's output sinks, shared by the two pipe readers: the log, the per-stream hashes, stdout for `ai_when`, and
/// the bytes passed on to the sub-chat (up to `chatCap`). Closed when the run ends, so an abandoned reader writes nothing.
private final class RunOutput: @unchecked Sendable {
    private let lock = NSLock(), log: FileHandle
    private var outHash = SHA256(), errHash = SHA256(), stdout = Data(), forwarded = 0, closed = false
    init(log: FileHandle) { self.log = log }
    /// Records a chunk; returns what goes on to the sub-chat.
    func take(_ data: Data,isOut: Bool) -> [(String,Data)] {
        lock.withLock {
            guard !closed else { return [] }
            try? log.write(contentsOf: data)
            if isOut { outHash.update(data: data); if stdout.count < ScriptRunner.stdoutCap { stdout.append(data.prefix(ScriptRunner.stdoutCap - stdout.count)) } } else { errHash.update(data: data) }
            guard forwarded < ScriptRunner.chatCap else { return [] }
            forwarded += data.count
            let chunk = (isOut ? "output" : "error",data)
            return forwarded < ScriptRunner.chatCap ? [chunk] : [chunk,("lifecycle",Data("[The chat stops here at 2 MB of output; the output continues in the log.]".utf8))]
        }
    }
    /// Hex hashes of stdout and stderr, and the kept stdout.
    func close() -> (String,String,Data) { lock.withLock { closed = true; return (ScriptRunner.hex(outHash.finalize()),ScriptRunner.hex(errHash.finalize()),stdout) } }
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
