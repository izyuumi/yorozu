public enum TranscriptTail {
    public static let probeSeconds = 8.0
    public static let minimumWindowSeconds = 30.0
    public static let minimumProbeSpeechSeconds = 2.0
    public static let minimumCoverage = 0.5

    public static func probe(of window: AudioWindow, sampleRate: Int, activity: VoiceActivity) -> AudioWindow? {
        let range = window.range
        guard window.voiced, Double(range.count) >= minimumWindowSeconds * Double(sampleRate) else { return nil }
        let start = max(range.lowerBound, range.upperBound - Int(probeSeconds * Double(sampleRate)))
        let probe = AudioWindow(range: start..<range.upperBound, activity: activity)
        return probe.speechSeconds >= minimumProbeSpeechSeconds ? probe : nil
    }

    public static func covers(_ transcript: String, tail: String) -> Bool {
        let tail = TranscriptSeam.tokens(in: Substring(tail)).map(\.key)
        guard !tail.isEmpty else { return true }
        let end = Array(TranscriptSeam.tokens(in: Substring(transcript)).map(\.key).suffix(2 * tail.count))
        return Double(commonSubsequence(tail, end)) / Double(tail.count) >= minimumCoverage
    }

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
