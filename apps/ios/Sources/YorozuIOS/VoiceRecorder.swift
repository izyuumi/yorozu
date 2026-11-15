import AVFoundation
import Observation
import Synchronization

/// Records the microphone as 16 kHz mono PCM for `Transcriber`, up to five minutes, with a loudness trail
/// for the waveform.
@MainActor @Observable
final class VoiceRecorder {
    nonisolated static let maxSeconds: Double = 300
    static let trail = 120

    /// Whether audio is coming in: `capped` once the limit is reached, when the clip so far is kept for `stop()`.
    enum Capture { case idle, running, capped }

    private(set) var capture = Capture.idle
    private(set) var levels: [Float] = []
    private(set) var seconds: Double = 0
    @ObservationIgnored private lazy var engine = AVAudioEngine()
    private let clip = Clip()
    private let cap: Int

    init(limit: Double = VoiceRecorder.maxSeconds) {
        cap = Int((limit * Double(Transcriber.sampleRate)).rounded())
    }

    func start() throws {
        clip.reset()
        levels = []
        seconds = 0
        #if DEBUG
        if PreviewScene.transcript != nil {
            capture = .running
            return play(PreviewScene.voiceClip())
        }
        #endif
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
            block: Self.tap(converter: converter, target: target, clip: clip, limit: cap) { [weak self] level, total in
                Task { @MainActor in self?.update(level: level, total: total) }
            })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        capture = .running
    }

    /// Stops recording and returns the clip.
    func stop() -> [Float] {
        capture = .idle
        #if DEBUG
        if let player {
            player.cancel()
            self.player = nil
            return clip.samples()
        }
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        return clip.samples()
    }

    private func update(level: Float, total: Int) {
        guard capture == .running else { return }
        show(level: level, total: total)
        if total >= cap {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            capture = .capped
        }
    }

    private func show(level: Float, total: Int) {
        seconds = Double(total) / Double(Transcriber.sampleRate)
        levels.append(level)
        if levels.count > Self.trail { levels.removeFirst(levels.count - Self.trail) }
    }

    nonisolated private static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        return max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
    }

    #if DEBUG
    @ObservationIgnored private var player: Task<Void, Never>?

    /// The preview's talk take: the clip, then silence, in place of the microphone, at the same pace.
    private func play(_ source: [Float]) {
        let chunk = Transcriber.sampleRate / 10
        player = Task { [weak self] in
            var offset = 0
            while !Task.isCancelled, let self {
                let part = (offset..<offset + chunk).map { $0 < source.count ? source[$0] : 0 }
                offset += chunk
                let total = part.withUnsafeBufferPointer { self.clip.append($0, limit: self.cap) }
                show(level: part.withUnsafeBufferPointer(Self.level), total: total)
                if total >= cap {
                    capture = .capped
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    #endif

    /// Built outside the main actor: the engine calls it on its own audio thread.
    nonisolated private static func tap(converter: AVAudioConverter, target: AVAudioFormat, clip: Clip, limit: Int,
                                        report: @escaping @Sendable (Float, Int) -> Void) -> AVAudioNodeTapBlock {
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
            report(level(samples), clip.append(samples, limit: limit))
        }
    }

    private final class Clip: Sendable {
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
