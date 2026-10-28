import AVFoundation
import Observation
import Synchronization

/// Records the microphone as 16 kHz mono PCM for `Transcriber`, up to five minutes, with a loudness trail
/// for the waveform.
@MainActor @Observable
final class VoiceRecorder {
    nonisolated static let maxSeconds: Double = 300
    static let trail = 120

    private(set) var levels: [Float] = []
    private(set) var seconds: Double = 0
    @ObservationIgnored private lazy var engine = AVAudioEngine()
    private let capture = Capture()

    func start() throws {
        capture.reset()
        levels = []
        seconds = 0
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif
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

    /// Stops recording and returns the clip.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        return capture.samples()
    }

    private func update(level: Float, seconds: Double) {
        guard engine.isRunning else { return }
        self.seconds = seconds
        levels.append(level)
        if levels.count > Self.trail { levels.removeFirst(levels.count - Self.trail) }
        if seconds >= Self.maxSeconds {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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
            let total = capture.append(samples, limit: Int(VoiceRecorder.maxSeconds) * Transcriber.sampleRate)
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
            report(level, Double(total) / Double(Transcriber.sampleRate))
        }
    }

    private final class Capture: Sendable {
        private let buffer = Mutex<[Float]>([])

        func reset() { buffer.withLock { $0 = [] } }
        func samples() -> [Float] { buffer.withLock { $0 } }

        func append(_ samples: UnsafeBufferPointer<Float>, limit: Int) -> Int {
            buffer.withLock {
                $0.append(contentsOf: samples.prefix(max(0, limit - $0.count)))
                return $0.count
            }
        }
    }
}
