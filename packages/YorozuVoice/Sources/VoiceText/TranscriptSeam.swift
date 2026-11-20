import Foundation

public enum TranscriptSeam {
    public static let shortestOverlap = 2
    public static let shortestCJKOverlap = 3
    public static let wordsPerSecond = 4.0
    public static let cjkCharactersPerSecond = 10.0

    public static func join(_ parts: [String]) -> String {
        join(parts, overlapSpeechSeconds: Array(repeating: AudioWindowPlan.overlapSeconds, count: max(0, parts.count - 1)))
    }

    public static func join(_ parts: [String], overlapSpeechSeconds: [Double]) -> String {
        precondition(overlapSpeechSeconds.count == max(0, parts.count - 1), "one overlap per seam")
        var text = ""
        for (index, part) in parts.enumerated() {
            var next = Substring(part.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !next.isEmpty else { continue }
            guard !text.isEmpty else { text = String(next); continue }
            let adjacent = !parts[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let speech = adjacent ? overlapSpeechSeconds[index - 1] : 0
            let tail = tokens(in: Substring(text))
            let head = tokens(in: next)
            if let end = overlap(tail: tail, head: head, speechSeconds: speech) {
                let ended = text.last?.isPunctuation == true
                next = next[end...].drop { $0.isWhitespace || (ended && $0.isPunctuation) }
                guard !next.isEmpty else { continue }
            }
            text += spaced(text.last, next.first) ? " " + next : String(next)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Token {
        let key: String
        let isCJK: Bool
        let end: String.Index
    }

    static func caps(speechSeconds: Double) -> (words: Int, characters: Int) {
        let seconds = min(max(speechSeconds, 0), AudioWindowPlan.overlapSeconds)
        func cap(_ rate: Double) -> Int { Int((seconds * rate - 1e-9).rounded(.up)) }
        return (cap(wordsPerSecond), cap(cjkCharactersPerSecond))
    }

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
