public struct AudioWindow: Equatable, Sendable {
    public let range: Range<Int>
    public let speechSeconds: Double
    public var voiced: Bool { speechSeconds > 0 }

    public init(range: Range<Int>, speechSeconds: Double) {
        self.range = range
        self.speechSeconds = speechSeconds
    }

    public init(range: Range<Int>, activity: VoiceActivity) {
        self.init(range: range, speechSeconds: activity.speechSeconds(in: range))
    }
}

public enum AudioWindowPlan {
    public static let preferredWindowSeconds = 90.0
    public static let minimumSplitSeconds = 15.0
    public static let audioTokensPerSecond = 12.5
    public static let promptReserve = 64
    public static let contextTokens = 8_192
    public static let overlapSeconds = 1.0
    public static let searchSeconds = 20.0

    public static func tokens(
        samples: Int, sampleRate: Int, audioTokensPerSecond: Double = audioTokensPerSecond,
        promptReserve: Int = promptReserve, budget: (Double) -> Int = TranscriptBudget.maxTokens
    ) -> Int {
        let seconds = Double(samples) / Double(sampleRate)
        return Int((seconds * audioTokensPerSecond).rounded(.up)) + promptReserve + budget(seconds)
    }

    public static func longestWindow(
        sampleRate: Int, contextTokens: Int = contextTokens, audioTokensPerSecond: Double = audioTokensPerSecond,
        promptReserve: Int = promptReserve, budget: (Double) -> Int = TranscriptBudget.maxTokens
    ) -> Int {
        func fits(_ samples: Int) -> Bool {
            tokens(samples: samples, sampleRate: sampleRate, audioTokensPerSecond: audioTokensPerSecond,
                   promptReserve: promptReserve, budget: budget) <= contextTokens
        }
        var low = 0
        var high = Int(Double(contextTokens) / audioTokensPerSecond * Double(sampleRate)) + 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        return max(1, low)
    }

    public static func windows(
        sampleCount: Int, sampleRate: Int, activity: VoiceActivity,
        contextTokens: Int = contextTokens, audioTokensPerSecond: Double = audioTokensPerSecond,
        promptReserve: Int = promptReserve, preferredWindowSeconds: Double = preferredWindowSeconds,
        overlapSeconds: Double = overlapSeconds, searchSeconds: Double = searchSeconds,
        budget: (Double) -> Int = TranscriptBudget.maxTokens
    ) -> [AudioWindow] {
        let count = max(0, sampleCount)
        let fitting = longestWindow(sampleRate: sampleRate, contextTokens: contextTokens,
                                    audioTokensPerSecond: audioTokensPerSecond, promptReserve: promptReserve, budget: budget)
        let preferred = preferredWindowSeconds * Double(sampleRate)
        let longest = preferred < Double(fitting) ? max(1, Int(preferred)) : fitting
        func window(_ range: Range<Int>) -> AudioWindow { AudioWindow(range: range, activity: activity) }
        guard count > longest else { return [window(0..<count)] }

        let overlap = max(0, Int(overlapSeconds * Double(sampleRate)))
        let search = max(0, Int(searchSeconds * Double(sampleRate)))
        var windows: [AudioWindow] = []
        var start = 0
        while count - start > longest {
            let limit = start + longest
            let earliest = min(limit, max(start + overlap + activity.frameLength, limit - search))
            let cut = quietestPoint(in: earliest..<limit, activity: activity) ?? limit
            windows.append(window(start..<cut))
            start = max(cut - overlap, start + 1)
        }
        windows.append(window(start..<count))
        return windows
    }

    public static func split(
        _ window: AudioWindow, sampleRate: Int, activity: VoiceActivity,
        overlapSeconds: Double = overlapSeconds, minimumSeconds: Double = minimumSplitSeconds
    ) -> [AudioWindow]? {
        let range = window.range
        let overlap = max(0, Int(overlapSeconds * Double(sampleRate)))
        let margin = max(range.count / 4, Int((minimumSeconds * Double(sampleRate)).rounded(.up)))
        guard range.lowerBound + margin < range.upperBound - margin + overlap else { return nil }
        let span = (range.lowerBound + margin)..<(range.upperBound - margin + overlap)
        let cut = quietestPoint(in: span, activity: activity) ?? (span.lowerBound + span.upperBound) / 2
        return [AudioWindow(range: range.lowerBound..<cut, activity: activity),
                AudioWindow(range: max(range.lowerBound, cut - overlap)..<range.upperBound, activity: activity)]
    }

    public static func overlapSpeechSeconds(_ previous: AudioWindow, _ next: AudioWindow, activity: VoiceActivity) -> Double {
        let start = max(previous.range.lowerBound, next.range.lowerBound)
        let end = min(previous.range.upperBound, next.range.upperBound)
        return start < end ? activity.speechSeconds(in: start..<end) : 0
    }

    static func quietestPoint(in span: Range<Int>, activity: VoiceActivity) -> Int? {
        let length = activity.frameLength
        let first = (span.lowerBound + length - 1) / length
        let last = min(span.upperBound / length, activity.voiced.count)
        guard first < last else { return nil }
        var best: (start: Int, count: Int)?
        var run: Int?
        for frame in first..<last {
            guard !activity.voiced[frame] else { run = nil; continue }
            let runStart = run ?? frame
            run = runStart
            if frame - runStart + 1 >= best?.count ?? 0 { best = (runStart, frame - runStart + 1) }
        }
        if let best { return (best.start * length + (best.start + best.count) * length) / 2 }
        var quietest = first
        for frame in first..<last where activity.energies[frame] <= activity.energies[quietest] { quietest = frame }
        return quietest * length + length / 2
    }
}
