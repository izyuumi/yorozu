import Foundation

/// Joins the transcripts of overlapping windows (`AudioWindowPlan`). Each window hears the last second of the
/// one before, so the words spoken there can come out twice; the repeat at each seam is dropped.
public enum TranscriptSeam {
    /// The shortest repeat dropped: one word said twice ("that that") may be what was said.
    public static let shortestOverlap = 2
    /// The longest repeat dropped, in words of spaced scripts…
    public static let longestWords = 16
    /// …and in characters of Chinese and Japanese, which are counted one by one.
    public static let longestCharacters = 24

    /// `parts` in order, empty ones skipped, each without the longest start (2…16 words, 2…24 CJK characters)
    /// that repeats the end of the text before it. Words compare case-, width- (NFKC) and punctuation-blind.
    /// Parts meet with a space, or without one where Chinese or Japanese meets.
    public static func join(_ parts: [String]) -> String {
        var text = ""
        for part in parts {
            var next = Substring(part.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !next.isEmpty else { continue }
            guard !text.isEmpty else { text = String(next); continue }
            let tail = tokens(in: Substring(text))
            let head = tokens(in: next)
            if let end = overlap(tail: tail, head: head) {
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

    /// Where the longest allowed repeat ends in the next part, nil when there is none.
    static func overlap(tail: [Token], head: [Token]) -> String.Index? {
        let most = min(tail.count, head.count, longestCharacters)
        guard most >= shortestOverlap else { return nil }
        for length in stride(from: most, through: shortestOverlap, by: -1) {
            let candidate = head[0..<length]
            guard candidate.elementsEqual(tail.suffix(length), by: { $0.key == $1.key }) else { continue }
            let characters = candidate.count { $0.isCJK }
            guard length - characters <= longestWords, characters <= longestCharacters else { continue }
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
