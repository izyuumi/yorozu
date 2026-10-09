import CoreServices
import Foundation
import TOML

/// `jobs.toml` next to `config.toml` (#319): one `[jobs.<id>]` table per job. Unknown keys are errors. Yorozu rewrites
/// the whole file in its canonical, commented layout, so hand-written comments are not kept. Problems are `ConfigError`s
/// whose key is `jobs.<id>` or `jobs.<id>.<key>` (`ConfigError.jobID` gives the id).
public enum JobsFile {
    public static func url(in root: URL) -> URL { root.appendingPathComponent("jobs.toml") }

    /// The validated jobs in file order; a missing file is no jobs.
    public static func load(_ url: URL) throws -> [JobSpec] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ConfigError(file: url.path,reason: error.localizedDescription) }
        return try parse(String(decoding: data,as: UTF8.self),file: url)
    }

    /// Read-modify-write under a lock: reads the file fresh, so an edit made since the last load is kept. For pause,
    /// resume, delete and retire. Throws when the file is invalid now or `change` leaves it invalid; nothing is written then.
    @discardableResult public static func update(_ url: URL, _ change: (inout [JobSpec]) throws -> Void) throws -> [JobSpec] {
        lock.lock(); defer { lock.unlock() }
        var jobs = try load(url); try change(&jobs); try write(jobs,to: url); return try load(url)
    }
    private static let lock = NSLock()

    /// Atomic (temporary file, fsync, then rename), mode 0600, in the order given; refuses invalid jobs and duplicate ids.
    public static func write(_ jobs: [JobSpec], to url: URL) throws {
        var ids = Set<String>()
        for job in jobs {
            guard ids.insert(job.id).inserted else { throw ConfigError(file: url.path,key: "jobs.\(job.id)",reason: "duplicate job id") }
            if let (key,reason) = problem(job) { throw ConfigError(file: url.path,key: key,reason: reason) }
        }
        let folder = url.deletingLastPathComponent(), temp = folder.appendingPathComponent(".jobs.toml." + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: temp.path,contents: Data(toml(jobs).utf8),attributes: [.posixPermissions: 0o600]) else { throw ConfigError(file: url.path,reason: "could not write \(temp.path)") }
        do { let handle = try FileHandle(forWritingTo: temp); defer { try? handle.close() }; try handle.synchronize() }
        catch { try? FileManager.default.removeItem(at: temp); throw ConfigError(file: url.path,reason: error.localizedDescription) }
        guard rename(temp.path,url.path) == 0 else {
            let code = errno; try? FileManager.default.removeItem(at: temp); throw ConfigError(file: url.path,reason: String(cString: strerror(code)))
        }
    }

    // MARK: Read
    static let keys = ["name","schedule","post","once","paused","retired","script","ai_when","instruction","timeout","model","executor","topic"]

    public static func parse(_ text: String, file: URL) throws -> [JobSpec] {
        func fail(_ key: String?, _ reason: String, line: Int? = nil) -> ConfigError { ConfigError(file: file.path,line: line ?? key.flatMap { Config.line(of: $0,in: text) },key: key,reason: reason) }
        var tree: [String:TOMLValue]
        do { tree = try TOMLDecoder().decode([String:JobsNode].self,from: text).mapValues(\.value) }
        catch let TOMLDecodingError.invalidSyntax(line,_,message) { throw fail(nil,message,line: line) }
        catch { throw fail(nil,"\(error)") }
        let root = tree.removeValue(forKey: "jobs")
        if let key = tree.keys.sorted().first { throw fail(key,"unknown key; each job is a [jobs.<id>] table") }
        guard let root else { return [] }
        guard case .table(let tables) = root else { throw fail("jobs","expected [jobs.<id>] tables") }
        var jobs: [(Int, JobSpec)] = []
        for (id,value) in tables {
            let base = "jobs.\(id)"
            guard case .table(var t) = value else { throw fail(base,"expected a [\(base)] table") }
            func take<V>(_ key: String, _ expected: String, _ cast: (TOMLValue) -> V?) throws -> V? {
                guard let value = t.removeValue(forKey: key) else { return nil }
                guard let v = cast(value) else { throw fail("\(base).\(key)","expected \(expected)") }
                return v
            }
            func string(_ key: String) throws -> String? { try take(key,"a string") { if case .string(let s) = $0 { s } else { nil } } }
            func bool(_ key: String) throws -> Bool? { try take(key,"true or false") { if case .boolean(let b) = $0 { b } else { nil } } }
            guard let name = try string("name") else { throw fail(base,"missing name") }
            let strings: (TOMLValue) -> [String]? = { value in
                guard case .array(let items) = value else { return nil }
                let list = items.compactMap { if case .string(let s) = $0 { s } else { nil } }
                return list.count == items.count ? list : nil
            }
            guard let schedule = try take("schedule","a list of cron strings, such as [\"0 8 * * 1-5\"]",strings) else { throw fail(base,"missing schedule") }
            var job = JobSpec(id: id,name: name,schedule: schedule)
            if let post = try take("post","\"always\" or \"notable\"",{ if case .string(let s) = $0 { JobSpec.Post(rawValue: s) } else { nil } }) { job.post = post }
            job.once = try bool("once") ?? false; job.paused = try bool("paused") ?? false; job.retired = try bool("retired") ?? false
            job.script = try string("script"); job.instruction = try string("instruction")
            job.aiWhen = try string("ai_when") ?? job.aiWhen
            if let timeout = try take("timeout","whole seconds",{ if case .integer(let i) = $0 { Int(exactly: i) } else { nil } }) { job.timeout = timeout }
            job.model = try string("model"); job.executor = try string("executor"); job.topic = try string("topic")
            if let key = t.keys.sorted().first { throw fail("\(base).\(key)","unknown key; known keys: " + keys.joined(separator: ", ")) }
            if let (key,reason) = problem(job) { throw fail(key,reason) }
            jobs.append((Config.line(of: base,in: text) ?? Int.max,job))
        }
        return jobs.sorted { ($0.0,$0.1.id) < ($1.0,$1.1.id) }.map(\.1)
    }

    /// The first invalid value of `job` as (dotted key, reason).
    public static func problem(_ job: JobSpec) -> (String, String)? {
        let base = "jobs.\(job.id)"
        if job.id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$",options: .regularExpression) == nil { return (base,"job id must be 1-40 of a-z, 0-9 and -, not starting with -") }
        if job.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ("\(base).name","expected a non-empty name") }
        if job.schedule.isEmpty { return ("\(base).schedule","expected at least one cron string, such as \"0 8 * * 1-5\"") }
        for expression in job.schedule { if let reason = Cron.problem(expression) { return ("\(base).schedule",reason) } }
        func blank(_ s: String?) -> Bool { s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
        if blank(job.script) && blank(job.instruction) { return (base,"needs a script, an instruction or both") }
        if !(1...86400).contains(job.timeout) { return ("\(base).timeout","expected 1-86400 seconds") }
        if !["always","changed"].contains(job.aiWhen), (try? NSRegularExpression(pattern: job.aiWhen)) == nil { return ("\(base).ai_when","expected \"always\", \"changed\" or a valid regular expression") }
        for (key,value) in [("model",job.model),("executor",job.executor),("topic",job.topic)] where value?.isEmpty == true { return ("\(base).\(key)","expected a non-empty string; leave the key out instead") }
        return nil
    }

    // MARK: Write
    static let header = """
    # Yorozu jobs. Yorozu rewrites this file in this layout; added comments are not kept.
    # One [jobs.<id>] table per job. <id> is 1-40 of a-z, 0-9 and - (not starting with -) and names ~/Yorozu/jobs/<id>/.
    #   name         what the job is called
    #   schedule     list of 5-field cron strings (minute hour day-of-month month day-of-week) in the Mac's time zone;
    #                a slot fires when any matches, such as ["0 8 * * 1-5"]
    #   post         "always": every result goes to the main chat; "notable": only notable ones (failures always are)
    #   once         true: run at the next slot, then retire
    #   paused       true: skip slots until resumed
    #   retired      true: a one-shot that has run
    #   script       shell text run by /bin/zsh in ~/Yorozu/jobs/<id>/; a new or changed script waits for the user's yes
    #   ai_when      when script output goes on to the instruction: "always", "changed" or a regular expression it must match
    #   instruction  the AI step
    #   timeout      script timeout in seconds, 1-86400 (default 600)
    #   model, executor  optional: run the AI step on this model or executor
    #   topic        the job's topic, set by Yorozu
    # A job needs a script, an instruction or both. Unknown keys are errors.

    """

    /// The canonical file: the header, then each job in the order given with its keys in a fixed order; defaults
    /// (`once`, `paused`, `retired` false, `ai_when` "always", `timeout` 600) and unset keys are left out.
    public static func toml(_ jobs: [JobSpec]) -> String {
        var out = header
        for job in jobs {
            out += "\n[jobs.\(Config.bare(job.id))]\n"
            func put(_ key: String, _ value: String?) { if let value { out += "\(key) = \(value)\n" } }
            put("name",Config.literal(.string(job.name)))
            put("schedule",Config.literal(.array(job.schedule.map { .string($0) })))
            put("post",Config.literal(.string(job.post.rawValue)))
            for (key,on) in [("once",job.once),("paused",job.paused),("retired",job.retired)] where on { put(key,"true") }
            put("script",job.script.map(text))
            if job.aiWhen != "always" { put("ai_when",Config.literal(.string(job.aiWhen))) }
            put("instruction",job.instruction.map(text))
            if job.timeout != 600 { put("timeout","\(job.timeout)") }
            put("model",job.model.map { Config.literal(.string($0)) })
            put("executor",job.executor.map { Config.literal(.string($0)) })
            put("topic",job.topic.map { Config.literal(.string($0)) })
        }
        return out
    }
    /// Multi-line text as a literal block (`'''`) when it can be one, so scripts stay readable.
    static func text(_ s: String) -> String {
        let plain = s.contains("\n") && !s.contains("'''") && !s.hasSuffix("'") && !s.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0.value == 0x7f }
        return plain ? "'''\n\(s)'''" : Config.literal(.string(s))
    }
}

extension ConfigError {
    /// The job a `jobs.toml` problem belongs to, from a `jobs.<id>…` key.
    public var jobID: String? {
        guard let key, key.hasPrefix("jobs.") else { return nil }
        let rest = key.dropFirst(5)
        return rest.isEmpty ? nil : String(rest.prefix { $0 != "." })
    }
}

/// Watches `jobs.toml` through its folder (FSEvents), so in-place edits and atomic saves (rename) are both caught.
/// Changes are debounced by 300 ms; unchanged bytes are ignored. `start()` reports the current file at once. Each report
/// carries the last valid jobs (an invalid file keeps the previous set; a missing file is no jobs) and the problem, if
/// any. Reports arrive on the watcher's queue.
public final class JobsWatcher: @unchecked Sendable {
    public struct Update: Sendable, Equatable {
        /// The last valid set.
        public var jobs: [JobSpec]
        /// Why the file on disk was not taken; nil when `jobs` is what the file says.
        public var error: ConfigError?
    }
    public let file: URL
    private let onChange: @Sendable (Update) -> Void
    private let queue = DispatchQueue(label: "yorozu.jobs-watcher"), onQueue = DispatchSpecificKey<Void>()
    private var stream: FSEventStreamRef?, pending: DispatchWorkItem?, seen: Data?, loaded = false, jobs: [JobSpec] = []
    private let paths: Set<String>
    public init(file: URL, onChange: @escaping @Sendable (Update) -> Void) {
        self.file = file; self.onChange = onChange
        paths = [file.path, file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path]
        queue.setSpecific(key: onQueue,value: ())
    }
    /// The last valid set.
    public var current: [JobSpec] { DispatchQueue.getSpecific(key: onQueue) == nil ? queue.sync { jobs } : jobs }
    public func start() {
        queue.sync {
            guard stream == nil else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
            var context = FSEventStreamContext(version: 0,info: Unmanaged.passUnretained(self).toOpaque(),retain: nil,release: nil,copyDescription: nil)
            let callback: FSEventStreamCallback = { _,info,count,paths,_,_ in
                let watcher = Unmanaged<JobsWatcher>.fromOpaque(info!).takeUnretainedValue()
                guard (unsafeBitCast(paths,to: NSArray.self) as? [String] ?? []).prefix(count).contains(where: watcher.paths.contains) else { return }
                watcher.pending?.cancel()
                let work = DispatchWorkItem { [weak watcher] in watcher?.reload() }
                watcher.pending = work; watcher.queue.asyncAfter(deadline: .now() + 0.3,execute: work)
            }
            let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            guard let stream = FSEventStreamCreate(nil,callback,&context,[file.deletingLastPathComponent().path] as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.05,FSEventStreamCreateFlags(flags)) else { return }
            self.stream = stream; FSEventStreamSetDispatchQueue(stream,queue); FSEventStreamStart(stream)
            reload()
        }
    }
    /// Runs on the watcher's queue, so no callback or reload is in flight while the stream goes away.
    public func stop() { DispatchQueue.getSpecific(key: onQueue) == nil ? queue.sync(execute: teardown) : teardown() }
    deinit { stop() }
    private func teardown() {
        pending?.cancel(); pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
    }
    private func reload() {
        let data = try? Data(contentsOf: file)
        guard !loaded || data != seen else { return }; loaded = true; seen = data
        do { jobs = try data.map { try JobsFile.parse(String(decoding: $0,as: UTF8.self),file: file) } ?? []; onChange(Update(jobs: jobs)) }
        catch { onChange(Update(jobs: jobs,error: error as? ConfigError ?? ConfigError(file: file.path,reason: error.localizedDescription))) }
    }
}

/// Any TOML value, so unknown keys and wrong types are reported instead of dropped.
private struct JobsNode: Decodable {
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
        else if let v = try? c.decode([JobsNode].self) { value = .array(v.map(\.value)) }
        else { value = .table(try c.decode([String:JobsNode].self).mapValues(\.value)) }
    }
}
