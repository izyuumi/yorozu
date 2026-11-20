import Foundation

public enum TranscriptDegeneration: Equatable, Sendable {
    case repetition
    case hintEcho
    case promptEcho

    public static let repeatLimit = 3
    public static let longestRun = 12

    public static func detect(in transcript: String, hints: [String]) -> TranscriptDegeneration? {
        if transcript.range(of: "Vocabulary:", options: .caseInsensitive) != nil { return .promptEcho }
        if repeats(words(in: transcript)) { return .repetition }
        if mostlyHints(transcript, hints: hints) { return .hintEcho }
        return nil
    }

    static func words(in text: String) -> [String] {
        var words: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { word, _, _, _ in
            if let word { words.append(word.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)) }
        }
        return words
    }

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
