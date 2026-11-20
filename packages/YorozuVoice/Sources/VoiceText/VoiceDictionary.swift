import Foundation

public struct VoiceDictionary: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var term: String
        public var heardAs: String

        public init(id: UUID = UUID(), term: String, heardAs: String = "") {
            (self.id, self.term, self.heardAs) = (id, term, heardAs)
        }
    }

    public static let maxEntries = 200
    public static let maxLength = 64
    public static let maxHints = 50

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.compactMap(Self.clean).prefix(Self.maxEntries))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decode([Entry].self, forKey: .entries))
    }

    public static func clean(_ entry: Entry) -> Entry? {
        func tidy(_ text: String) -> String {
            String(text.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces).prefix(maxLength))
        }
        let term = tidy(entry.term)
        guard !term.isEmpty else { return nil }
        let heardAs = tidy(entry.heardAs)
        return Entry(id: entry.id, term: term, heardAs: heardAs.caseInsensitiveCompare(term) == .orderedSame ? "" : heardAs)
    }

    public var isFull: Bool { entries.count >= Self.maxEntries }

    @discardableResult
    public mutating func save(_ entry: Entry) -> Bool {
        guard let entry = Self.clean(entry) else { return false }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            return true
        }
        guard !isFull else { return false }
        entries.append(entry)
        return true
    }

    public mutating func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }

    public var hints: [String] {
        var seen = Set<String>()
        return Array(entries.map(\.term).filter { seen.insert($0.lowercased()).inserted }.prefix(Self.maxHints))
    }

    private struct Rule {
        let pattern: [String]
        let term: String
        let startBoundary: Bool
        let endBoundary: Bool
    }

    public func apply(to text: String) -> String {
        let rules = Self.rules(for: entries)
        guard !rules.isEmpty, !text.isEmpty else { return text }
        let original = Array(text)
        let folded = original.map(Self.fold)
        var byFirst: [String: [Rule]] = [:]
        for rule in rules { byFirst[rule.pattern[0], default: []].append(rule) }

        var output = ""
        var index = 0
        scan: while index < original.count {
            for rule in byFirst[folded[index]] ?? [] {
                let end = index + rule.pattern.count
                guard end <= original.count, Array(folded[index..<end]) == rule.pattern else { continue }
                if rule.startBoundary, index > 0, Self.isWordCharacter(original[index - 1]) { continue }
                if rule.endBoundary, end < original.count, Self.isWordCharacter(original[end]) { continue }
                output += Self.cased(rule.term, like: original[index..<end])
                index = end
                continue scan
            }
            output.append(original[index])
            index += 1
        }
        return output
    }

    private static func rules(for entries: [Entry]) -> [Rule] {
        var rules: [Rule] = []
        var seen = Set<[String]>()
        for entry in entries {
            let source = entry.heardAs.isEmpty ? entry.term : entry.heardAs
            if entry.heardAs.isEmpty, !source.contains(where: { $0.isCased }) { continue }
            let pattern = Array(source).map(fold)
            guard let first = source.first, let last = source.last, seen.insert(pattern).inserted else { continue }
            rules.append(Rule(pattern: pattern, term: entry.term,
                startBoundary: isWordCharacter(first), endBoundary: isWordCharacter(last)))
        }
        return rules.enumerated().sorted { ($0.element.pattern.count, $1.offset) > ($1.element.pattern.count, $0.offset) }.map(\.element)
    }

    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber) && !character.unicodeScalars.contains(where: isUnspaced)
    }

    static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3005...0x3007, 0x3040...0x30FF, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3134F: true
        default: false
        }
    }

    private static func cased(_ term: String, like match: ArraySlice<Character>) -> String {
        guard let first = term.first, let matched = match.first(where: \.isCased),
              !term.contains(where: \.isUppercase), matched.isUppercase else { return term }
        return first.uppercased() + term.dropFirst()
    }
}

private extension Character {
    var isCased: Bool { isUppercase || isLowercase }
}
