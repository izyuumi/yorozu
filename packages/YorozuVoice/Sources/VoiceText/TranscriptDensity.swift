public enum TranscriptDensity {
    public static let minimumWindows = 3
    public static let minimumSpeechSeconds = 10.0
    public static let sparseRatio = 0.7
    public static let improvement = 1.15

    public static func letters(in text: String) -> Int {
        text.unicodeScalars.count { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    public static func sparse(_ windows: [(text: String, speechSeconds: Double)]) -> [Int] {
        let judged = windows.indices.filter { windows[$0].speechSeconds >= minimumSpeechSeconds }
        guard judged.count >= minimumWindows else { return [] }
        let densities = judged.map { Double(letters(in: windows[$0].text)) / windows[$0].speechSeconds }
        let sorted = densities.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return zip(judged, densities).filter { $0.1 < sparseRatio * median }.map(\.0)
    }

    public static func isBetter(_ replacement: String, than original: String) -> Bool {
        let new = letters(in: replacement)
        return new > 0 && Double(new) >= improvement * Double(letters(in: original))
    }
}
