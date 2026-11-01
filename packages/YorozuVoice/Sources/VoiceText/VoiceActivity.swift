/// Which 0.1 s frames of a clip hold speech, judged by loudness alone.
///
/// Mirrors WhisperKit's `EnergyVAD` (argmax-oss-swift 1.1.1, `Sources/WhisperKit/Core/Audio/EnergyVAD.swift`
/// and `AudioProcessor.calculateVoiceActivityInChunks`), which `WhisperSpeechEngine` uses through
/// `chunkingStrategy: .vad`: the RMS energy of each 0.1 s frame against a threshold. VoiceText has no
/// dependencies, so the approach is copied rather than imported. WhisperKit's threshold is a fixed 0.02; here
/// it follows the clip, a fraction of its loud frames, so a quiet recording still shows its pauses, with a
/// floor so a clip of room noise counts as silence.
public struct VoiceActivity: Equatable, Sendable {
    /// WhisperKit's default frame length.
    public static let frameSeconds = 0.1
    /// Frames at or below this RMS are silence whatever the clip: a quarter of WhisperKit's fixed 0.02, as
    /// microphone levels vary from device to device.
    public static let floor: Float = 0.005
    /// Frames at or below this share of the clip's loud level are silence.
    public static let fraction: Float = 0.1
    /// The clip's loud level: the energy this share of its frames stays under.
    public static let percentile = 0.95

    /// Samples per frame; the last frame may be shorter.
    public let frameLength: Int
    /// RMS energy of each frame.
    public let energies: [Float]
    /// The energy a frame must exceed to count as speech.
    public let threshold: Float
    /// Whether each frame holds speech.
    public let voiced: [Bool]

    /// Measures `samples`, recorded at `sampleRate`, in 0.1 s frames.
    public init(samples: [Float], sampleRate: Int) {
        let frameLength = max(1, Int(Double(sampleRate) * Self.frameSeconds))
        var energies: [Float] = []
        energies.reserveCapacity(samples.count / frameLength + 1)
        var start = 0
        while start < samples.count {
            let end = min(start + frameLength, samples.count)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            energies.append((sum / Float(end - start)).squareRoot())
            start = end
        }
        self.init(energies: energies, frameLength: frameLength)
    }

    /// Frames already measured, `frameLength` samples each.
    public init(energies: [Float], frameLength: Int) {
        let threshold = Self.threshold(for: energies)
        self.frameLength = max(1, frameLength)
        self.energies = energies
        self.threshold = threshold
        voiced = energies.map { $0 > threshold }
    }

    /// Whether any frame touching `range` (in samples) holds speech.
    public func isVoiced(_ range: Range<Int>) -> Bool {
        speechSeconds(in: range) > 0
    }

    /// Seconds of `range` (in samples) that fall in speech frames.
    public func speechSeconds(in range: Range<Int>) -> Double {
        guard !range.isEmpty else { return 0 }
        let first = range.lowerBound / frameLength
        let last = min((range.upperBound - 1) / frameLength, voiced.count - 1)
        guard first <= last else { return 0 }
        var samples = 0
        for frame in first...last where voiced[frame] {
            samples += min(range.upperBound, (frame + 1) * frameLength) - max(range.lowerBound, frame * frameLength)
        }
        return Double(samples) / Double(frameLength) * Self.frameSeconds
    }

    static func threshold(for energies: [Float]) -> Float {
        let sorted = energies.filter { !$0.isNaN }.sorted()
        guard !sorted.isEmpty else { return floor }
        let loud = sorted[Int(Double(sorted.count - 1) * percentile)]
        return max(floor, fraction * loud)
    }
}
