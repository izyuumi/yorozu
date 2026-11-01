/// Whether a window's transcript reaches the end of its speech. LFM3-Audio sometimes stops a window early,
/// repeating an earlier sentence and ending seconds before the audio does, with no other sign of failure; the
/// lost sentence is too short for `TranscriptDensity` to notice. So the end of a long window is decoded on its
/// own as a probe, and a window whose transcript doesn't end with what the probe says is decoded again in
/// halves (`AudioWindowPlan.split`).
public enum TranscriptTail {
    /// How much of a window's end the probe decodes.
    public static let probeSeconds = 8.0
    /// The shortest window probed; a short dictation doesn't pay a second decode.
    public static let minimumWindowSeconds = 30.0
    /// Speech the probe's span needs to be decoded.
    public static let minimumProbeSpeechSeconds = 2.0
    /// The share of the probe's words or CJK characters the transcript's end must hold. Measured with this
    /// measure: a window that stopped 12 s early 0.29; 15 complete English and Japanese windows 0.86–1.00.
    public static let minimumCoverage = 0.5

    /// The last `probeSeconds` of `window`, measured by `activity`; nil when the window is shorter than
    /// `minimumWindowSeconds`, silent, or that span holds less than `minimumProbeSpeechSeconds` of speech.
    public static func probe(of window: AudioWindow, sampleRate: Int, activity: VoiceActivity) -> AudioWindow? {
        let range = window.range
        guard window.voiced, Double(range.count) >= minimumWindowSeconds * Double(sampleRate) else { return nil }
        let start = max(range.lowerBound, range.upperBound - Int(probeSeconds * Double(sampleRate)))
        let probe = AudioWindow(range: start..<range.upperBound, activity: activity)
        return probe.speechSeconds >= minimumProbeSpeechSeconds ? probe : nil
    }

    /// Whether `transcript` ends with what `tail`, the probe's transcript, says: the longest common
    /// subsequence of the tail's words and CJK characters and the transcript's last twice as many is at
    /// least `minimumCoverage` of the tail's (`TranscriptSeam.tokens`: case-, width- and punctuation-blind).
    /// An empty tail is covered.
    public static func covers(_ transcript: String, tail: String) -> Bool {
        let tail = TranscriptSeam.tokens(in: Substring(tail)).map(\.key)
        guard !tail.isEmpty else { return true }
        let end = Array(TranscriptSeam.tokens(in: Substring(transcript)).map(\.key).suffix(2 * tail.count))
        return Double(commonSubsequence(tail, end)) / Double(tail.count) >= minimumCoverage
    }

    /// The length of the longest common subsequence of `a` and `b`.
    static func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = x == y ? diagonal + 1 : max(above, row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }
}
