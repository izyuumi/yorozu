/// How much text a window's speech came back as, to find a window LFM3-Audio silently skipped part of: it
/// stops transcribing for a stretch and carries on, so the window's transcript is short for its speech
/// with no other sign of failure. A clip's windows hold the same speaker and language, so a window far less
/// dense than the others' median is decoded again in halves (`AudioWindowPlan.split`).
public enum TranscriptDensity {
    /// Windows with `minimumSpeechSeconds` of speech a clip needs before any is judged against the others.
    public static let minimumWindows = 3
    /// Speech a window needs to be judged; a short one's density says little.
    public static let minimumSpeechSeconds = 10.0
    /// A window below this share of the median density is sparse.
    public static let sparseRatio = 0.7
    /// How much denser the halves' transcript must be to replace the window's.
    public static let improvement = 1.15

    /// Letters and digits in `text`, each CJK character one: what a transcript says, without spaces or
    /// punctuation, comparable across scripts within one clip.
    public static func letters(in text: String) -> Int {
        text.unicodeScalars.count { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    /// The indices of `windows` (each its transcript and seconds of speech) whose transcript is sparse:
    /// below `sparseRatio` of the median letters per speech second, among windows with at least
    /// `minimumSpeechSeconds` of speech, when there are `minimumWindows` such windows. Others are never sparse.
    public static func sparse(_ windows: [(text: String, speechSeconds: Double)]) -> [Int] {
        let judged = windows.indices.filter { windows[$0].speechSeconds >= minimumSpeechSeconds }
        guard judged.count >= minimumWindows else { return [] }
        let densities = judged.map { Double(letters(in: windows[$0].text)) / windows[$0].speechSeconds }
        let sorted = densities.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return zip(judged, densities).filter { $0.1 < sparseRatio * median }.map(\.0)
    }

    /// Whether `replacement`, a second decode of the same audio, says at least `improvement` times as much
    /// as `original`.
    public static func isBetter(_ replacement: String, than original: String) -> Bool {
        let new = letters(in: replacement)
        return new > 0 && Double(new) >= improvement * Double(letters(in: original))
    }
}
