/// A stretch of a clip decoded on its own, in samples.
public struct AudioWindow: Equatable, Sendable {
    public let range: Range<Int>
    /// How much of it holds speech (`VoiceActivity`), in seconds.
    public let speechSeconds: Double
    /// Whether any of it holds speech; a silent window need not be decoded.
    public var voiced: Bool { speechSeconds > 0 }

    public init(range: Range<Int>, speechSeconds: Double) {
        self.range = range
        self.speechSeconds = speechSeconds
    }

    /// `range`, measured by `activity`.
    public init(range: Range<Int>, activity: VoiceActivity) {
        self.init(range: range, speechSeconds: activity.speechSeconds(in: range))
    }
}

/// How a clip is split so each decode fits LFM3-Audio's context and stays complete: the audio's tokens, the
/// prompt around them and the transcript's budget (`TranscriptBudget`) must all fit, and no window is longer
/// than `preferredWindowSeconds`. A clip within both is decoded whole; a longer one in windows of at most
/// that length, each cut at a pause and overlapping the next a little, so a word cut at the seam is heard
/// whole by one of the two (`TranscriptSeam` drops the repeat).
public enum AudioWindowPlan {
    /// The longest window decoded, though the context fits about 178 s. LFM3-Audio silently skips stretches
    /// of long windows, not quite the same from run to run. Measured on 10-minute English and Japanese
    /// readings: a 177 s window came back with a third of its speech; 115–120 s windows were mixed (Japanese
    /// 233–348 s skipped about 50 s of speech on every run, while its halves and 233–323 s were complete);
    /// every 90 s span tried, seven of them, was complete. Shorter isn't always safer (one 60 s span lost a
    /// fifth), so a window that still comes back sparse is decoded again in halves (`TranscriptDensity`).
    public static let preferredWindowSeconds = 90.0
    /// The shortest half `split` makes.
    public static let minimumSplitSeconds = 15.0
    /// Measured with mtmd's tokenizer and the pinned LFM3-Audio-2B files: one audio token per 80 ms, the
    /// same for English and Japanese, from 33 s (418 tokens) to 597 s (7,468 tokens).
    public static let audioTokensPerSecond = 12.5
    /// The prompt around the audio measured 17 tokens; the rest is margin for hints and rounding.
    public static let promptReserve = 64
    /// The decoder's context (`Transcriber.contextTokens`).
    public static let contextTokens = 8_192
    /// How much of the end of one window the next one hears again.
    public static let overlapSeconds = 1.0
    /// How far back from a window's longest end a pause is looked for.
    public static let searchSeconds = 20.0

    /// Context positions a decode of `samples` uses at most: audio, prompt and transcript budget.
    public static func tokens(
        samples: Int, sampleRate: Int, audioTokensPerSecond: Double = audioTokensPerSecond,
        promptReserve: Int = promptReserve, budget: (Double) -> Int = TranscriptBudget.maxTokens
    ) -> Int {
        let seconds = Double(samples) / Double(sampleRate)
        return Int((seconds * audioTokensPerSecond).rounded(.up)) + promptReserve + budget(seconds)
    }

    /// The most samples one decode fits in `contextTokens` (about 178 s for 8,192); at least one.
    public static func longestWindow(
        sampleRate: Int, contextTokens: Int = contextTokens, audioTokensPerSecond: Double = audioTokensPerSecond,
        promptReserve: Int = promptReserve, budget: (Double) -> Int = TranscriptBudget.maxTokens
    ) -> Int {
        func fits(_ samples: Int) -> Bool {
            tokens(samples: samples, sampleRate: sampleRate, audioTokensPerSecond: audioTokensPerSecond,
                   promptReserve: promptReserve, budget: budget) <= contextTokens
        }
        // Tokens grow with the clip, so the longest fit is found by bisection.
        var low = 0
        var high = Int(Double(contextTokens) / audioTokensPerSecond * Double(sampleRate)) + 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        return max(1, low)
    }

    /// The windows that cover `0..<sampleCount`, in order: one for a clip that fits and is no longer than
    /// `preferredWindowSeconds`, otherwise each at most the shorter of the two, ending at the quietest point
    /// of its last `searchSeconds` (the middle of the longest silent run, else the quietest frame) and the
    /// next starting `overlapSeconds` before that.
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
            // Cut late enough that the next window, starting `overlap` earlier, still moves forward.
            let earliest = min(limit, max(start + overlap + activity.frameLength, limit - search))
            let cut = quietestPoint(in: earliest..<limit, activity: activity) ?? limit
            windows.append(window(start..<cut))
            start = max(cut - overlap, start + 1)
        }
        windows.append(window(start..<count))
        return windows
    }

    /// `window` in two halves, for a second try at a window whose decode failed or came back sparse
    /// (`TranscriptDensity`): cut at the quietest point
    /// of its middle half, the second half starting `overlapSeconds` before the cut. Nil when a half would be
    /// shorter than `minimumSeconds`.
    public static func split(
        _ window: AudioWindow, sampleRate: Int, activity: VoiceActivity,
        overlapSeconds: Double = overlapSeconds, minimumSeconds: Double = minimumSplitSeconds
    ) -> [AudioWindow]? {
        let range = window.range
        let overlap = max(0, Int(overlapSeconds * Double(sampleRate)))
        let margin = max(range.count / 4, Int((minimumSeconds * Double(sampleRate)).rounded(.up)))
        // The second half, starting `overlap` before the cut, must still be `minimumSeconds` long.
        guard range.lowerBound + margin < range.upperBound - margin + overlap else { return nil }
        let span = (range.lowerBound + margin)..<(range.upperBound - margin + overlap)
        let cut = quietestPoint(in: span, activity: activity) ?? (span.lowerBound + span.upperBound) / 2
        return [AudioWindow(range: range.lowerBound..<cut, activity: activity),
                AudioWindow(range: max(range.lowerBound, cut - overlap)..<range.upperBound, activity: activity)]
    }

    /// The sample to cut at among the whole frames inside `span`: the middle of the longest run of silent
    /// frames (the latest of equals), else the middle of the quietest frame; nil when no whole frame fits.
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
