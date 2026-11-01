import CryptoKit
import Foundation
import Observation
import OSLog
import VoiceText
#if os(iOS)
import BackgroundAssets
import Network
import System
#endif

/// One downloadable voice model (`VoiceCatalog.swift` in packages/YorozuVoice pins its files). iPhone and iPad
/// get each as an Apple-hosted asset pack (`scripts/voice_asset_pack.sh` builds them), so no third party sees
/// the download; the Mac downloads it from Hugging Face into Application Support, resumable, excluded from
/// backup, checked against the pinned hashes. LFM3-Audio's files sit at the top of the folder, as they always
/// have; every other model has a subfolder of its own, on disk and inside its pack.
@MainActor @Observable
final class VoiceModel {
    nonisolated static let enabledKey = "voiceInput"
    nonisolated static let languageKey = "voiceInputLanguage"
    nonisolated static let engineKey = "voiceInputEngine"
    nonisolated static let dictionaryKey = "voiceDictionary"

    /// The downloadable models, by engine; Apple's has none.
    static let all: [VoiceEngineID: VoiceModel] = Dictionary(uniqueKeysWithValues: VoiceEngineID.allCases.compactMap { engine in
        engine.model.map { (engine, VoiceModel(engine: engine, spec: $0)) }
    })

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
        /// The model's asset pack is not in App Store Connect yet.
        case unavailable
        case failed(String)
    }

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "VoiceModel")

    let engine: VoiceEngineID
    let spec: VoiceModelSpec
    private(set) var state: State = .absent
    private(set) var received: Int64 = 0
    /// The download is held back because the only network is cellular, a hotspot or in Low Data Mode.
    private(set) var waitingForWiFi = false
    private var download: Task<Void, Never>?
    private var cellular = false
    private let directory = clientSupportDirectory.appending(path: "VoiceModel", directoryHint: .isDirectory)

    var totalBytes: Int64 { spec.totalBytes }
    var hasFiles: Bool { received > 0 }

    /// Where a file of the model is once downloaded.
    func url(of file: VoiceModelSpec.File) -> URL { final(file) }

    /// The folder the model's runtime loads: the one holding its top-level files.
    var folderURL: URL {
        guard let top = spec.files.first(where: { !$0.path.contains("/") }) else { return directory.appending(path: spec.folder) }
        return final(top).deletingLastPathComponent()
    }

    private init(engine: VoiceEngineID, spec: VoiceModelSpec) {
        self.engine = engine
        self.spec = spec
        received = onDisk()
        if spec.files.allSatisfy({ size(of: final($0)) == $0.bytes }) { state = .ready }
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
        if #available(iOS 26, *) { Task { [packID = spec.packID] in try? await AssetPackManager.shared.remove(assetPackWithID: packID) } }
        #endif
        if spec.folder.isEmpty {
            for file in spec.files {
                try? FileManager.default.removeItem(at: directory.appending(path: file.path))
                try? FileManager.default.removeItem(at: part(file))
            }
        } else {
            try? FileManager.default.removeItem(at: directory.appending(path: spec.folder, directoryHint: .isDirectory))
        }
        received = 0
        state = .absent
    }

    /// On iPhone and iPad, marks the model unavailable when App Store Connect has no pack for it yet.
    func checkAvailability() async {
        #if os(iOS)
        guard #available(iOS 26, *), state == .absent || state == .unavailable, download == nil else { return }
        do {
            _ = try await AssetPackManager.shared.assetPack(withID: spec.packID)
            if state == .unavailable { state = .absent }
        } catch {
            if case .assetPackNotFound? = error as? ManagedBackgroundAssetsError { state = .unavailable }
        }
        #endif
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
            for file in spec.files where size(of: final(file)) != file.bytes {
                try await fetch(file)
            }
            #endif
            guard !Task.isCancelled else { return }
            state = .ready
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            Self.log.error("Voice model download failed: \(String(describing: error), privacy: .public)")
            state = Self.state(for: error)
        }
        received = onDisk()
        download = nil
        waitingForWiFi = false
        cellular = false
        VoiceSetup.shared.refresh()
    }

    private func fetch(_ file: VoiceModelSpec.File) async throws {
        let part = part(file)
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        if size(of: part) > file.bytes { try FileManager.default.removeItem(at: part) }
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let offset = size(of: part)
        if offset < file.bytes {
            var request = URLRequest(url: file.url)
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

    private static func state(for error: any Error) -> State {
        #if os(iOS)
        if #available(iOS 27, *), let error = error as? AssetPackManager.LocalAvailabilityError,
            let failure = error.failures.values.first {
            return state(for: failure)
        }
        if #available(iOS 26, *), case .assetPackNotFound? = error as? ManagedBackgroundAssetsError { return .unavailable }
        #endif
        if let failure = error as? Failure, let message = failure.errorDescription { return .failed(message) }
        if error is URLError { return .failed(error.localizedDescription) }
        return .failed(String(localized: "The voice model couldn’t be downloaded. Try again."))
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
        let (packID, total) = (spec.packID, Double(totalBytes))
        let progress = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: packID) {
                if case .downloading(_, let progress) = update { received = Int64(progress.fractionCompleted * total) }
            }
        }
        defer { progress.cancel() }
        try await manager.ensureLocalAvailability(of: manager.assetPack(withID: packID))
    }
    #endif

    private func final(_ file: VoiceModelSpec.File) -> URL {
        let location = spec.location(of: file)
        #if os(iOS)
        if #available(iOS 26, *), let url = try? AssetPackManager.shared.url(for: FilePath(location)) { return url }
        #endif
        return directory.appending(path: location)
    }

    private func part(_ file: VoiceModelSpec.File) -> URL { directory.appending(path: spec.location(of: file) + ".part") }

    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func onDisk() -> Int64 {
        spec.files.reduce(0) { $0 + max(size(of: final($1)), size(of: part($1))) }
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
