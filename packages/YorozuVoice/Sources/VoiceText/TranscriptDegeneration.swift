import Foundation

/// How a transcript decoded with vocabulary hints can go wrong: on audio the model can't make out, hints
/// give it something to say, so it loops or reads the vocabulary back instead of transcribing.
public enum TranscriptDegeneration: Equatable, Sendable {
    /// The same word or run of words three or more times in a row ("万事屋万事屋万事屋…").
    case repetition
    /// Most of the transcript is hint terms, at least two different ones.
    case hintEcho
    /// The instruction's "Vocabulary:" list came back as the transcript.
    case promptEcho

    /// Repeats in a row that count as a loop. "no no" is speech; a third time in a row is treated as a loop.
    public static let repeatLimit = 3
    /// The longest run of words checked for repeats.
    public static let longestRun = 12

    /// What went wrong with `transcript`, decoded with `hints`; nil when it reads like a transcript.
    public static func detect(in transcript: String, hints: [String]) -> TranscriptDegeneration? {
        if transcript.range(of: "Vocabulary:", options: .caseInsensitive) != nil { return .promptEcho }
        if repeats(words(in: transcript)) { return .repetition }
        if mostlyHints(transcript, hints: hints) { return .hintEcho }
        return nil
    }

    /// Words as the system splits them, Japanese and Chinese included; punctuation and spaces dropped.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { word, _, _, _ in
            if let word { words.append(word.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)) }
        }
        return words
    }

    /// True when some run of 1…`longestRun` words appears `repeatLimit` times back to back.
    static func repeats(_ words: [String]) -> Bool {
        let limit = repeatLimit
        guard words.count >= limit else { return false }
        for length in 1...min(longestRun, words.count / limit) {
            for start in 0...(words.count - length * limit) {
                let run = words[start..<start + length]
                if (1..<limit).allSatisfy({ words[start + $0 * length..<start + ($0 + 1) * length].elementsEqual(run) }) { return true }
            }
        }
        return false
    }

    /// True when two or more different hint terms cover more than half the transcript's letters and digits.
    /// One term alone may be all someone said ("Yorozu"), or said twice to get attention.
    static func mostlyHints(_ transcript: String, hints: [String]) -> Bool {
        let total = letterCount(transcript)
        guard total > 0 else { return false }
        var rest = transcript
        var found = 0
        for hint in hints.filter({ letterCount($0) > 0 }).sorted(by: { $0.count > $1.count }) {
            var seen = false
            while let range = rest.range(of: hint, options: [.caseInsensitive, .widthInsensitive]) {
                rest.replaceSubrange(range, with: " ")
                seen = true
            }
            if seen { found += 1 }
        }
        return found >= 2 && (total - letterCount(rest)) * 2 > total
    }

    private static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.count { CharacterSet.alphanumerics.contains($0) }
    }
}
