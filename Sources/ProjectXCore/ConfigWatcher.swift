import CoreServices
import Foundation

/// Watches `config.toml` through its folder (FSEvents), so in-place edits and atomic saves (rename) are both caught.
/// Changes are debounced by 300 ms; an unchanged file is ignored. A valid file is reported and becomes `current`;
/// an invalid or missing one is reported as a `ConfigError` and `current` keeps the last valid config.
public final class ConfigWatcher: @unchecked Sendable {
    public let file: URL
    public private(set) var current: Config?
    private let onChange: @Sendable (Result<Config, ConfigError>) -> Void
    private let queue = DispatchQueue(label: "yorozu.config-watcher")
    private var stream: FSEventStreamRef?, pending: DispatchWorkItem?, seen: Data?
    private let paths: Set<String>
    /// `current` is the config already in force; reads of the file as it is now are not reported.
    public init(file: URL, current: Config?, onChange: @escaping @Sendable (Result<Config, ConfigError>) -> Void) {
        self.file = file; self.current = current; self.onChange = onChange; seen = try? Data(contentsOf: file)
        paths = [file.path, file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path]
    }
    public func start() {
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
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil; pending?.cancel()
    }
    deinit { stop() }
    private func reload() {
        let data = try? Data(contentsOf: file)
        guard data != seen else { return }; seen = data
        guard let data else { return onChange(.failure(ConfigError(file: file.path,reason: "the file is missing; the last valid settings stay in force"))) }
        do { let config = try Config.parse(String(decoding: data,as: UTF8.self),file: file); current = config; onChange(.success(config)) }
        catch { onChange(.failure(error as? ConfigError ?? ConfigError(file: file.path,reason: error.localizedDescription))) }
    }
}
