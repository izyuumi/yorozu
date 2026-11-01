import Foundation
import UserNotifications
import VoiceText
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// The app's one owner of voice input: a `VoiceSession` per conversation over the one `VoiceRecorder`, so the
/// composer, the Live Activity's Stop and Cancel (`RecordingControl`) and the Talk control reach the same recording.
/// Clips stay in `ClipStore` until their text reaches the composer; a clip an earlier run left behind is transcribed
/// into its conversation's composer when the app comes forward, never sent. Demo mode keeps clips in memory only.
@MainActor
final class Dictation {
    static let shared = Dictation()
    static let clipLifetime: TimeInterval = 7 * 24 * 3_600

    let recorder = VoiceRecorder()
    private var sessions: [String: VoiceSession] = [:]
    private weak var recording: VoiceSession?
    private weak var model: AppModel?
    /// Clips this run holds, which recovery leaves alone.
    private var owned: Set<UUID> = []
    /// Closed clips waiting for the device to unlock before they get complete protection.
    private var unsealed: Set<UUID> = []
    private var observer: (any NSObjectProtocol)?
    private let directory = clientSupportDirectory.appending(path: "VoiceClips", directoryHint: .isDirectory)
    private lazy var store = ClipStore(directory: directory, protection: { try Self.protect($0, $1) })

    private init() {
        recorder.onEffect = { [weak self] effect in self?.recording?.handle(effect) }
    }

    /// At launch, before it finishes (the continued-processing handler must register only once).
    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        #if os(iOS)
        RecordingControl.handler = { [weak self] action in
            guard let session = self?.recording, session.phase == .recording else { return }
            switch action {
            case .stop: session.stop(.liveActivity)
            case .cancel: session.cancel()
            }
        }
        ContinuedTranscription.register()
        observer = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.sealWaiting() }
        }
        #endif
    }

    func session(for convId: String) -> VoiceSession {
        if let session = sessions[convId] { return session }
        let session = VoiceSession(convId: convId)
        sessions[convId] = session
        return session
    }

    /// One microphone: a recording in another conversation stops into its own composer first.
    func willRecord(_ session: VoiceSession) {
        if let other = recording, other !== session, other.phase == .recording { other.stop() }
        recording = session
    }

    /// The app is in front: seals what waited for the unlock, picks up clips an earlier run left, and transcribes
    /// the ones that waited.
    func cameForward() {
        guard let model, !model.isDemo else { return }
        sealWaiting()
        store.purge(olderThan: Date().addingTimeInterval(-Self.clipLifetime))
        for meta in store.pending() where !owned.contains(meta.id) {
            guard let samples = try? store.samples(meta.id) else { continue }
            guard !samples.isEmpty else {
                store.delete(meta.id)
                continue
            }
            owned.insert(meta.id)
            if !session(for: meta.convId).recover(samples, id: meta.id) { owned.remove(meta.id) }
        }
        for session in sessions.values where session.queued { session.retry() }
    }

    func title(_ convId: String) -> String? { model?.conversations[convId]?.title }

    // MARK: Clips

    /// The clip's file, written as it is spoken; nil in demo mode or when it can't be created (the clip then lives in
    /// memory only, as before).
    func beginClip(_ id: UUID, convId: String) -> ClipWriter? {
        guard let model, !model.isDemo,
              let writer = try? store.begin(ClipMeta(id: id, convId: convId, createdAt: Date(), purpose: .insert)) else { return nil }
        owned.insert(id)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return writer
    }

    /// Complete protection once the clip is closed, now if the device is unlocked, else on unlock.
    func seal(_ id: UUID) {
        guard owned.contains(id) else { return }
        unsealed.insert(id)
        sealWaiting()
    }

    func delete(_ id: UUID) {
        guard owned.remove(id) != nil else { return }
        unsealed.remove(id)
        store.delete(id)
    }

    private func sealWaiting() {
        #if os(iOS)
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        #endif
        for id in unsealed where (try? store.seal(id)) != nil { unsealed.remove(id) }
    }

    nonisolated private static func protect(_ url: URL, _ protection: ClipProtection) throws {
        #if os(iOS)
        let type: FileProtectionType = protection == .complete ? .complete : .completeUnlessOpen
        try FileManager.default.setAttributes([.protectionKey: type], ofItemAtPath: url.path)
        #endif
    }

    // MARK: Background

    static var inBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    /// The transcript, or nil when it has to wait for the app to come forward (`TranscriptionPlan`): an engine on
    /// the GPU with the app in the background, or a failure there (out of background time, or no GPU).
    static func transcribe(_ clip: VoiceClip) async -> Result<String, Error>? {
        #if os(iOS)
        let plan = TranscriptionPlan.choose(usesGPU: VoiceSetup.shared.engine?.usesGPU ?? true, inFront: !inBackground,
            continuedProcessing: ContinuedTranscription.available, backgroundGPU: ContinuedTranscription.backgroundGPU)
        let result: Result<String, Error>
        switch plan {
        case .queue: return nil
        case .backgroundTask: result = await underBackgroundTask(clip)
        case .continuedProcessing:
            if let done = await ContinuedTranscription.run(clip) { result = done } else { result = await clip.transcribe() }
        case .foreground: result = await clip.transcribe()
        }
        if case .failure = result, inBackground, !Task.isCancelled { return nil }
        return result
        #else
        return await clip.transcribe()
        #endif
    }

    enum Notice { case cap, transcriptReady }

    /// Only while the app is in the background; in front, the composer shows it. Opens the conversation.
    func notify(_ notice: Notice, convId: String) {
        #if os(iOS)
        guard let model, !model.isDemo, Self.inBackground else { return }
        let content = UNMutableNotificationContent()
        switch notice {
        case .cap:
            content.title = String(localized: "Recording Stopped")
            content.body = String(localized: "Recording stopped at the 5-minute limit.")
        case .transcriptReady:
            content.title = String(localized: "Transcript Ready")
            content.body = String(localized: "The text is in the message field for you to review.")
        }
        content.sound = .default
        content.userInfo = ["convId": convId]
        // One per conversation: the transcript replaces the cap's notice.
        let request = UNNotificationRequest(identifier: "voice:\(convId)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
        #endif
    }

    #if os(iOS)
    private static func underBackgroundTask(_ clip: VoiceClip) async -> Result<String, Error> {
        let work = Task { await clip.transcribe() }
        let task = BackgroundTask(name: "Transcribing voice input") { work.cancel() }
        defer { task.end() }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    #endif
}

extension VoiceEngineID {
    /// Whether the engine needs the GPU, which iOS denies an app in the background (read from each engine's code):
    /// - Apple Speech: SpeechAnalyzer runs in the system's speech service. No.
    /// - Nemotron: FluidAudio loads its CoreML models with `MLModelConfigurationUtils.defaultConfiguration()`,
    ///   `.cpuAndNeuralEngine`. No.
    /// - Whisper: WhisperKit's default `ModelComputeOptions` runs the mel spectrogram on `.cpuAndGPU` (encoder and
    ///   decoder on the Neural Engine). Yes.
    /// - LFM3-Audio: llama.cpp's Apple build runs on Metal and `llama_model_default_params` offloads every layer. Yes.
    var usesGPU: Bool {
        switch self {
        case .apple, .nemotron: false
        case .whisperTurbo, .whisperSmall, .lfm: true
        }
    }
}

#if os(iOS)
/// A `UIApplication` background task that ends once, from either side.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String, expired: @escaping @MainActor @Sendable () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            expired()
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// A GPU engine's transcription in an iOS 26 continued-processing task, submitted while the app is in front, so it
/// may finish after the owner leaves; the system shows its progress. Expiry cancels it and the clip waits.
@MainActor
enum ContinuedTranscription {
    static let prefix = "to.yumi.yorozu.ios.voice-transcribe."
    /// Starters by task identifier, until the system runs the task.
    private static var waiting: [String: (BGTask) -> Void] = [:]

    static var available: Bool {
        if #available(iOS 26, *) { true } else { false }
    }

    static var backgroundGPU: Bool {
        if #available(iOS 26, *) { BGTaskScheduler.supportedResources.contains(.gpu) } else { false }
    }

    static func register() {
        guard #available(iOS 26, *) else { return }
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + "*", using: .main) { task in
            MainActor.assumeIsolated {
                guard let start = waiting.removeValue(forKey: task.identifier) else { return task.setTaskCompleted(success: false) }
                start(task)
            }
        }
    }

    /// The transcript, or nil when the system didn't take the task (then the caller runs it in front).
    static func run(_ clip: VoiceClip) async -> Result<String, Error>? {
        guard #available(iOS 26, *) else { return nil }
        let id = prefix + UUID().uuidString
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: String(localized: "Transcribing Voice Input"),
            subtitle: String(localized: "The text goes into the message field."))
        request.strategy = .fail
        request.requiredResources = .gpu
        let running = Running()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Result<String, Error>?, Never>) in
                running.done = done
                waiting[id] = { task in
                    guard let task = task as? BGContinuedProcessingTask else { return running.finish(nil) }
                    running.start(clip, in: task)
                }
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    waiting[id] = nil
                    return running.finish(nil)
                }
                // `.fail` runs it at once or not at all.
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if waiting.removeValue(forKey: id) != nil { running.finish(nil) }
                }
            }
        } onCancel: {
            Task { @MainActor in running.cancel() }
        }
    }

    /// One task's transcription, its progress and its single answer.
    @available(iOS 26, *) @MainActor
    private final class Running {
        var done: CheckedContinuation<Result<String, Error>?, Never>?
        private var work: Task<Result<String, Error>, Never>?
        private var cancelled = false

        func start(_ clip: VoiceClip, in task: BGContinuedProcessingTask) {
            guard !cancelled else {
                task.setTaskCompleted(success: false)
                return finish(nil)
            }
            let work = Task { await clip.transcribe() }
            self.work = work
            task.expirationHandler = { work.cancel() }
            // No engine reports its progress, so it advances with the time a clip this long usually takes.
            let progress = task.progress
            progress.totalUnitCount = 100
            let estimate = max(10, Double(clip.samples.count) / Double(Transcriber.sampleRate))
            let started = ContinuousClock.now
            let ticker = Task {
                while !Task.isCancelled {
                    let elapsed = (ContinuousClock.now - started) / .seconds(1)
                    progress.completedUnitCount = Int64(min(95, elapsed / estimate * 100))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            nonisolated(unsafe) let task = task
            Task {
                let result = await work.value
                ticker.cancel()
                progress.completedUnitCount = 100
                if case .success = result { task.setTaskCompleted(success: true) } else { task.setTaskCompleted(success: false) }
                finish(result)
            }
        }

        func cancel() {
            cancelled = true
            work?.cancel()
        }

        func finish(_ result: Result<String, Error>?) {
            done?.resume(returning: result)
            done = nil
        }
    }
}
#endif
