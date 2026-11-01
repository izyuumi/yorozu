import AVFoundation
import Observation
import Synchronization

/// Records the microphone as 16 kHz mono PCM for the speech engines, up to `RecordingLimits.maxSeconds`, with a
/// loudness trail for the waveform. It keeps recording in the background (the `audio` background mode, with the
/// system's microphone indicator). Interruptions, route and engine configuration changes go through
/// `RecordingMachine`: the recorder runs its engine effects and hands the rest to `onEffect`. Every sample also
/// streams to the clip's `ClipWriter`, off the audio thread.
@MainActor @Observable
final class VoiceRecorder {
    static let trail = 120

    private(set) var levels: [Float] = []
    private(set) var seconds: Double = 0
    private(set) var phase = RecordingPhase.idle
    /// `persistClip`, `discardClip`, `announceCap` and `updateActivity`, after the machine moved on.
    @ObservationIgnored var onEffect: (RecordingEffect) -> Void = { _ in }
    @ObservationIgnored private var machine = RecordingMachine()
    @ObservationIgnored private lazy var engine = AVAudioEngine()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    private let capture = Capture()

    /// Starts a recording that also streams into `writer` (none in demo mode, or when the clip couldn't be created).
    func start(writer: ClipWriter?) throws {
        capture.reset(writer: writer)
        levels = []
        seconds = 0
        do {
            try activate()
            try startEngine()
        } catch {
            deactivate()
            throw error
        }
        observe()
        send(.start)
    }

    func send(_ event: RecordingEvent) {
        let effects = machine.handle(event)
        phase = machine.phase
        var failed = false
        for effect in effects {
            switch effect {
            case .startEngine: break  // `start` started it, to report a failure.
            case .pauseEngine: engine.pause()
            case .resumeEngine, .restartEngine: failed = !restart() || failed
            case .stopEngine: stopEngine()
            case .persistClip, .discardClip, .announceCap, .updateActivity: onEffect(effect)
            }
        }
        if failed { send(.engineRestartFailed) }
    }

    /// The samples so far.
    func samples() -> [Float] { capture.samples() }

    /// Closes the clip's file once every queued write landed.
    func closeClip() async { await capture.close() }

    private func update(level: Float, seconds: Double) {
        guard phase == .recording else { return }
        self.seconds = seconds
        levels.append(level)
        if levels.count > Self.trail { levels.removeFirst(levels.count - Self.trail) }
        send(.captured(seconds: seconds))
    }

    // MARK: Engine

    private func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif
    }

    private func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Taps the input in its current format, which a new route may have changed.
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Transcriber.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target)
        else { throw VoiceModel.Failure(String(localized: "No microphone is available.")) }
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: 4_096, format: format,
            block: Self.tap(converter: converter, target: target, capture: capture) { [weak self] level, seconds in
                Task { @MainActor in self?.update(level: level, seconds: seconds) }
            })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// After an interruption or a route change: the same clip, from the input as it is now.
    private func restart() -> Bool {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try activate()
            try startEngine()
            return true
        } catch {
            return false
        }
    }

    private func stopEngine() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        deactivate()
    }

    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.routeChanged(inputLost: true)) }
            },
        ]
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.send(.interruptionBegan)
                case .ended: self?.send(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
                default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.send(.routeChanged(inputLost: true)) }
        })
        #endif
    }

    /// Built outside the main actor: the engine calls it on its own audio thread.
    nonisolated private static func tap(converter: AVAudioConverter, target: AVAudioFormat, capture: Capture,
                                        report: @escaping @Sendable (Float, Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
            let total = capture.append(samples, limit: Int(RecordingLimits.maxSeconds) * Transcriber.sampleRate)
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
            report(level, Double(total) / Double(Transcriber.sampleRate))
        }
    }

    /// The clip in memory, for the engines, and on disk through its writer, for when the app doesn't survive.
    private final class Capture: Sendable {
        private struct State {
            var samples: [Float] = []
            var writer: ClipWriter?
        }

        private let state = Mutex(State())
        private let disk = DispatchQueue(label: "to.yumi.yorozu.voice-clip")

        func reset(writer: ClipWriter?) { state.withLock { $0 = State(writer: writer) } }
        func samples() -> [Float] { state.withLock { $0.samples } }

        func append(_ samples: UnsafeBufferPointer<Float>, limit: Int) -> Int {
            let (total, chunk, writer) = state.withLock { state in
                let chunk = Array(samples.prefix(max(0, limit - state.samples.count)))
                state.samples.append(contentsOf: chunk)
                return (state.samples.count, chunk, state.writer)
            }
            if let writer, !chunk.isEmpty { disk.async { try? writer.append(chunk) } }
            return total
        }

        func close() async {
            guard let writer = state.withLock({ state in defer { state.writer = nil }; return state.writer }) else { return }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                disk.async {
                    try? writer.close()
                    done.resume()
                }
            }
        }
    }
}
