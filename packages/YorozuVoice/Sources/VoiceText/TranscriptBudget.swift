public enum TranscriptBudget {
    public static let tokensPerSecond = 11.0
    public static let safetyFactor = 3.0
    public static let minimum = 128
    public static let maximum = 8_192

    public static func maxTokens(seconds: Double) -> Int {
        guard seconds > 0 else { return minimum }
        let tokens = (seconds * tokensPerSecond * safetyFactor).rounded(.up)
        return Int(min(Double(maximum), max(Double(minimum), tokens)))
    }
}
