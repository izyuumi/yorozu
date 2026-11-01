import Foundation

/// Joins the transcripts of overlapping windows (`AudioWindowPlan`). Each window hears the last second of the
/// one before, so the words spoken there can come out twice; the repeat at each seam is dropped, as long as
/// the speech in that overlap could have said it. The cut is usually in a pause, so an overlap often holds
/// no speech, and then a repeat across the seam is what was said ("言った" + "言ったことを…").
public enum TranscriptSeam {
    /// The shortest repeat dropped: one word said twice ("that that") may be what was said.
    public static let shortestOverlap = 2
    /// The shortest repeat dropped that is all Chinese or Japanese, counted in characters: two ("本当") are
    /// often one word.
    public static let shortestCJKOverlap = 3
    /// The most words of spaced scripts a second of speech holds, about fast speech's rate…
    public static let wordsPerSecond = 4.0
    /// …and the most Chinese or Japanese characters, which are counted one by one.
    public static let cjkCharactersPerSecond = 10.0

    /// `parts` in order, each seam's overlap taken as a full `AudioWindowPlan.overlapSeconds` of speech.
    public static func join(_ parts: [String]) -> String {
        join(parts, overlapSpeechSeconds: Array(repeating: AudioWindowPlan.overlapSeconds, count: max(0, parts.count - 1)))
    }

    /// `parts` in order, empty ones skipped, each without the longest start that repeats the end of the text
    /// before it: at least `shortestOverlap` tokens (`shortestCJKOverlap` when all CJK), at most the words and
    /// CJK characters (`wordsPerSecond`, `cjkCharactersPerSecond`) that the speech in the seam's overlap holds.
    /// `overlapSpeechSeconds[i]` is that speech between `parts[i]` and `parts[i + 1]`
    /// (`AudioWindowPlan.overlapSpeechSeconds`), at most `AudioWindowPlan.overlapSeconds`; after an empty part
    /// there is no shared audio. Words compare case-, width- (NFKC) and punctuation-blind. Parts meet with a
    /// space, or without one where Chinese or Japanese meets.
    public static func join(_ parts: [String], overlapSpeechSeconds: [Double]) -> String {
        precondition(overlapSpeechSeconds.count == max(0, parts.count - 1), "one overlap per seam")
        var text = ""
        for (index, part) in parts.enumerated() {
            var next = Substring(part.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !next.isEmpty else { continue }
            guard !text.isEmpty else { text = String(next); continue }
            // Only the part just before shares audio with this one.
            let adjacent = !parts[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let speech = adjacent ? overlapSpeechSeconds[index - 1] : 0
            let tail = tokens(in: Substring(text))
            let head = tokens(in: next)
            if let end = overlap(tail: tail, head: head, speechSeconds: speech) {
                // The repeat's own punctuation stays unless the text already ends with some.
                let ended = text.last?.isPunctuation == true
                next = next[end...].drop { $0.isWhitespace || (ended && $0.isPunctuation) }
                guard !next.isEmpty else { continue }
            }
            text += spaced(text.last, next.first) ? " " + next : String(next)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One word or one CJK character: its normalised form and where it ends in the original text.
    struct Token {
        let key: String
        let isCJK: Bool
        let end: String.Index
    }

    /// The most words and CJK characters `speechSeconds` of overlap can hold, clamped to
    /// `0...AudioWindowPlan.overlapSeconds`.
    static func caps(speechSeconds: Double) -> (words: Int, characters: Int) {
        let seconds = min(max(speechSeconds, 0), AudioWindowPlan.overlapSeconds)
        // The epsilon keeps a measured 0.30000000000000004 s at 3 characters, not 4.
        func cap(_ rate: Double) -> Int { Int((seconds * rate - 1e-9).rounded(.up)) }
        return (cap(wordsPerSecond), cap(cjkCharactersPerSecond))
    }

    /// Where the longest allowed repeat ends in the next part, nil when there is none.
    static func overlap(tail: [Token], head: [Token], speechSeconds: Double) -> String.Index? {
        let caps = caps(speechSeconds: speechSeconds)
        let most = min(tail.count, head.count, caps.words + caps.characters)
        guard most >= shortestOverlap else { return nil }
        for length in stride(from: most, through: shortestOverlap, by: -1) {
            let candidate = head[0..<length]
            guard candidate.elementsEqual(tail.suffix(length), by: { $0.key == $1.key }) else { continue }
            let characters = candidate.count { $0.isCJK }
            let words = length - characters
            guard words <= caps.words, characters <= caps.characters else { continue }
            guard words > 0 || characters >= shortestCJKOverlap else { continue }
            return candidate.last!.end
        }
        return nil
    }

    /// Words split at spaces, with punctuation dropped; each Han, Hiragana or Katakana character a token.
    static func tokens(in text: Substring) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var wordEnd = text.startIndex
        func flush() {
            if !word.isEmpty { tokens.append(Token(key: word, isCJK: false, end: wordEnd)) }
            word = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let after = text.index(after: index)
            for character in String(text[index]).precomposedStringWithCompatibilityMapping.lowercased() {
                if character.isWhitespace {
                    flush()
                } else if isCJK(character) {
                    flush()
                    tokens.append(Token(key: String(character), isCJK: true, end: after))
                } else if !character.isPunctuation, !character.isSymbol {
                    word.append(character)
                    wordEnd = after
                }
            }
            index = after
        }
        flush()
        return tokens
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
        }
    }

    /// No space where either side is Chinese or Japanese, their punctuation (、。「」) and full-width forms
    /// included, nor before punctuation that ends a repeat ("tomorrow" + ".").
    private static func spaced(_ left: Character?, _ right: Character?) -> Bool {
        if let right, right.isPunctuation, !"([{\"'“‘".contains(right) { return false }
        func wide(_ character: Character?) -> Bool {
            guard let character else { return false }
            return isCJK(character) || character.unicodeScalars.contains {
                (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
            }
        }
        return !wide(left) && !wide(right)
    }
}
