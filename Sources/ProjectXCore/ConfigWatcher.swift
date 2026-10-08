import CoreServices
import Foundation

/// Watches `config.toml` through its folder (FSEvents), so in-place edits and atomic saves (rename) are both caught.
/// Changes are debounced by 300 ms; an unchanged file is ignored. A valid file is reported as a `Config`;
/// an invalid or missing one as a `ConfigError`. All state lives on the watcher's queue.
public final class ConfigWatcher: @unchecked Sendable {
    public let file: URL
    private let onChange: @Sendable (Result<Config, ConfigError>) -> Void
    private let queue = DispatchQueue(label: "yorozu.config-watcher"), onQueue = DispatchSpecificKey<Void>()
    private var stream: FSEventStreamRef?, pending: DispatchWorkItem?, seen: Data?
    private let paths: Set<String>
    /// `seen` is the file's bytes as loaded at launch: a later difference, including an edit made during launch, is reported.
    public init(file: URL, seen: Data?, onChange: @escaping @Sendable (Result<Config, ConfigError>) -> Void) {
        self.file = file; self.seen = seen; self.onChange = onChange
        paths = [file.path, file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path]
        queue.setSpecific(key: onQueue,value: ())
    }
    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(version: 0,info: Unmanaged.passUnretained(self).toOpaque(),retain: nil,release: nil,copyDescription: nil)
            let callback: FSEventStreamCallback = { _,info,count,paths,_,_ in
                let watcher = Unmanaged<ConfigWatcher>.fromOpaque(info!).takeUnretainedValue()
                guard (unsafeBitCast(paths,to: NSArray.self) as? [String] ?? []).prefix(count).contains(where: watcher.paths.contains) else { return }
                watcher.pending?.cancel()
                let work = DispatchWorkItem { [weak watcher] in watcher?.reload() }
                watcher.pending = work; watcher.queue.asyncAfter(deadline: .now() + 0.3,execute: work)
            }
            let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            guard let stream = FSEventStreamCreate(nil,callback,&context,[file.deletingLastPathComponent().path] as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.05,FSEventStreamCreateFlags(flags)) else { return }
            self.stream = stream; FSEventStreamSetDispatchQueue(stream,queue); FSEventStreamStart(stream)
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
        guard data != seen else { return }; seen = data
        guard let data else { return onChange(.failure(ConfigError(file: file.path,reason: "the file is missing; the last valid settings stay in force"))) }
        do { onChange(.success(try Config.parse(String(decoding: data,as: UTF8.self),file: file))) }
        catch { onChange(.failure(error as? ConfigError ?? ConfigError(file: file.path,reason: error.localizedDescription))) }
    }
}
