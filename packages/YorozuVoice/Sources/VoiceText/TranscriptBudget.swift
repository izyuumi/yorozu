/// How many tokens LFM3-Audio may write for a clip. Speech yields only a few tokens a second, so a decode
/// that outruns this is looping: it stops there instead of running on to the end of the context.
public enum TranscriptBudget {
    /// Above the fastest real speech measured on an M4 Mac mini: 10.4 tokens a second for letters and digits
    /// read out at 380 words a minute in Japanese; ordinary English and Japanese speech gave 3 to 6, and
    /// English at 380 words a minute 8.2.
    public static let tokensPerSecond = 11.0
    /// Headroom over that rate, so fast or dense speech is never cut off.
    public static let safetyFactor = 3.0
    /// A short clip still has room for a few sentences.
    public static let minimum = 128
    /// The decoder's context, which bounds every decode anyway.
    public static let maximum = 8_192

    public static func maxTokens(seconds: Double) -> Int {
        guard seconds > 0 else { return minimum }
        let tokens = (seconds * tokensPerSecond * safetyFactor).rounded(.up)
        return Int(min(Double(maximum), max(Double(minimum), tokens)))
    }
}
