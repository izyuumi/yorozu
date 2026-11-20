public struct VoiceActivity: Equatable, Sendable {
    public static let frameSeconds = 0.1
    public static let floor: Float = 0.005
    public static let fraction: Float = 0.1
    public static let percentile = 0.95

    public let frameLength: Int
    public let energies: [Float]
    public let threshold: Float
    public let voiced: [Bool]

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

    public init(energies: [Float], frameLength: Int) {
        let threshold = Self.threshold(for: energies)
        self.frameLength = max(1, frameLength)
        self.energies = energies
        self.threshold = threshold
        voiced = energies.map { $0 > threshold }
    }

    public func isVoiced(_ range: Range<Int>) -> Bool {
        speechSeconds(in: range) > 0
    }

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
