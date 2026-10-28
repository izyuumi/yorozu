import CryptoKit
import Foundation
import Observation
#if os(iOS)
import BackgroundAssets
import Network
import System
#endif

/// The opt-in voice input model (LFM3-Audio-2B, GGUF). iPhone and iPad get it as an Apple-hosted asset pack
/// (`scripts/voice_asset_pack.sh` builds it), so no third party sees the download; the Mac downloads it from
/// Hugging Face into Application Support, resumable, excluded from backup, checked against pinned hashes.
@MainActor @Observable
final class VoiceModel {
    static let shared = VoiceModel()
    static let enabledKey = "voiceInput"
    static let languageKey = "voiceInputLanguage"

    struct File {
        let name: String
        let bytes: Int64
        let sha256: String
    }

    static let revision = "fcfae9027c00a6f3f872c48a841cfeb77e2b5a1c"
    static let files = [
        File(name: "LFM3-Audio-2B-Q4_K_M.gguf", bytes: 1_099_626_016,
            sha256: "9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2"),
        File(name: "mmproj-LFM3-Audio-2B-Q8_0.gguf", bytes: 337_862_080,
            sha256: "26601e904245a85bd8f3cf320a629e897cfc01c1d09369e8b4fd951f13024d3e"),
    ]
    static let totalBytes = files.reduce(0) { $0 + $1.bytes }
    static let supported = Transcriber.available && enoughMemory && appleHosting
    /// About 6 GB of RAM: those devices report a little under 6 GiB, 4 GB ones well below this.
    static let enoughMemory = ProcessInfo.processInfo.physicalMemory >= 5 << 30
    static let packID = "VoiceModel"
    /// iPhone and iPad need iOS 26 for Apple-hosted asset packs.
    static var appleHosting: Bool {
        #if os(iOS)
        if #available(iOS 26, *) { return true }
        return false
        #else
        true
        #endif
    }

    enum State: Equatable {
        case absent, downloading, ready
        case failed(String)
    }

    private(set) var state: State = .absent
    private(set) var received: Int64 = 0
    /// The download is held back because the only network is cellular, a hotspot or in Low Data Mode.
    private(set) var waitingForWiFi = false
    private var download: Task<Void, Never>?
    private var cellular = false
    private let directory = clientSupportDirectory.appending(path: "VoiceModel", directoryHint: .isDirectory)

    var modelURL: URL { final(Self.files[0]) }
    var projectorURL: URL { final(Self.files[1]) }
    var hasFiles: Bool { received > 0 }

    private init() {
        received = onDisk()
        if Self.files.allSatisfy({ size(of: final($0)) == $0.bytes }) { state = .ready }
    }

    /// Starts or resumes the download; does nothing while one runs or once the model is ready. It waits for
    /// Wi-Fi unless `cellular` allows expensive and Low Data Mode networks for this download.
    func start(cellular: Bool = false) {
        if cellular, !self.cellular { pause() }
        guard state != .ready, download == nil else { return }
        self.cellular = cellular
        state = .downloading
        download = Task { await run() }
    }

    /// Stops the download and keeps what has arrived, to resume later.
    func pause() {
        download?.cancel()
        download = nil
        waitingForWiFi = false
        if state == .downloading { state = .absent }
    }

    func delete() {
        pause()
        #if os(iOS)
        if #available(iOS 26, *) { Task { try? await AssetPackManager.shared.remove(assetPackWithID: Self.packID) } }
        #endif
        try? FileManager.default.removeItem(at: directory)
        received = 0
        state = .absent
    }

    private func run() async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try excluded.setResourceValues(values)
            #if os(iOS)
            if #available(iOS 26, *) { try await fetchPack() }
            #else
            for file in Self.files where size(of: final(file)) != file.bytes {
                try await fetch(file)
            }
            #endif
            guard !Task.isCancelled else { return }
            state = .ready
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            state = .failed(error.localizedDescription)
        }
        received = onDisk()
        download = nil
        waitingForWiFi = false
        cellular = false
    }

    private func fetch(_ file: File) async throws {
        let part = directory.appending(path: file.name + ".part")
        if size(of: part) > file.bytes { try FileManager.default.removeItem(at: part) }
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let offset = size(of: part)
        if offset < file.bytes {
            var request = URLRequest(url: URL(string: "https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/\(Self.revision)/\(file.name)")!)
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let before = onDisk() - offset
            try await PartWriter(file: part, offset: offset, cellular: cellular) { [weak self] written in
                Task { @MainActor in
                    guard let self, self.download != nil else { return }
                    self.received = before + written
                    self.waitingForWiFi = false
                }
            } waiting: { [weak self] in
                Task { @MainActor in if self?.download != nil { self?.waitingForWiFi = true } }
            }.run(request)
        }
        guard size(of: part) == file.bytes else { throw Failure(String(localized: "The download was interrupted. Try again.")) }
        let digest = try await Task.detached(priority: .utility) { try Self.sha256(of: part) }.value
        guard digest == file.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw Failure(String(localized: "The downloaded model was damaged. Try again."))
        }
        try FileManager.default.moveItem(at: part, to: final(file))
    }

    #if os(iOS)
    /// Waits for Wi-Fi unless cellular was allowed, then has the system download the pack from Apple.
    @available(iOS 26, *)
    private func fetchPack() async throws {
        if !cellular {
            for await path in NWPathMonitor() {
                if path.status == .satisfied, !path.isExpensive, !path.isConstrained { break }
                waitingForWiFi = true
            }
            waitingForWiFi = false
            try Task.checkCancellation()
        }
        let manager = AssetPackManager.shared
        let progress = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: Self.packID) {
                if case .downloading(_, let progress) = update { received = Int64(progress.fractionCompleted * Double(Self.totalBytes)) }
            }
        }
        defer { progress.cancel() }
        try await manager.ensureLocalAvailability(of: manager.assetPack(withID: Self.packID))
    }
    #endif

    private func final(_ file: File) -> URL {
        #if os(iOS)
        if #available(iOS 26, *), let url = try? AssetPackManager.shared.url(for: FilePath(file.name)) { return url }
        #endif
        return directory.appending(path: file.name)
    }

    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func onDisk() -> Int64 {
        Self.files.reduce(0) { $0 + max(size(of: final($1)), size(of: directory.appending(path: $1.name + ".part"))) }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 8 << 20) }), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Streams one HTTP response into a partial file, appending from `offset` when the server honours the range.
private final class PartWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private var written: Int64
    private var lastReport = Date.distantPast
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private let report: @Sendable (Int64) -> Void
    private let waiting: @Sendable () -> Void
    private let cellular: Bool

    init(file: URL, offset: Int64, cellular: Bool, report: @escaping @Sendable (Int64) -> Void,
         waiting: @escaping @Sendable () -> Void) throws {
        handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(offset))
        written = offset
        self.cellular = cellular
        self.report = report
        self.waiting = waiting
    }

    func run(_ request: URLRequest) async throws {
        // Without consent the download holds on cellular, hotspots and Low Data Mode and resumes on Wi-Fi.
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = cellular
        configuration.allowsConstrainedNetworkAccess = cellular
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        switch (response as? HTTPURLResponse)?.statusCode {
        case 206:
            completionHandler(.allow)
        case 200:
            do {
                try handle.truncate(atOffset: 0)
                written = 0
                completionHandler(.allow)
            } catch {
                failure = error
                completionHandler(.cancel)
            }
        case let code:
            failure = VoiceModel.Failure(String(localized: "The download failed (HTTP \(code ?? 0)). Try again."))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        waiting()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
        } catch {
            failure = error
            dataTask.cancel()
        }
        if Date().timeIntervalSince(lastReport) > 0.25 {
            lastReport = Date()
            report(written)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.close()
        report(written)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
