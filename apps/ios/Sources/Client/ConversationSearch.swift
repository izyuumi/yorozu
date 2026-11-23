import Foundation

struct ConversationSearch: Sendable {
    struct Hit: Identifiable, Equatable, Sendable {
        let convId: String
        let messageId: String?
        let title: String
        let ts: Int64
        let archived: Bool
        let snippet: String
        let highlights: [Range<String.Index>]

        var id: String { messageId ?? convId }
    }

    struct Group: Identifiable, Equatable, Sendable {
        let convId: String
        let title: String
        let archived: Bool
        var hits: [Hit]

        var id: String { convId }
    }

    struct Result: Equatable, Sendable {
        var groups: [Group] = []
        var truncated = false
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    static let context = 24
    static let length = 160
    private static let markdown = Set("*_`~[]<>\\&")

    let terms: [String]

    var isEmpty: Bool { terms.isEmpty }

    init(_ query: String) { terms = Self.terms(query) }

    static func terms(_ query: String) -> [String] {
        let closers: [Character: Character] = ["\"": "\"", "「": "」", "“": "”"]
        var terms: [String] = []
        var current = ""
        var closer: Character?
        func flush() {
            let term = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty { terms.append(term) }
            current = ""
        }
        for character in query {
            if let open = closer {
                if character == open { flush(); closer = nil } else { current.append(character) }
            } else if let close = closers[character] {
                flush()
                closer = close
            } else if character.isWhitespace {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return terms
    }

    static func plain(_ text: String) -> String {
        guard text.contains(where: markdown.contains) else { return text }
        let plain = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return plain.map { String($0.characters) } ?? text
    }

    private static func find(_ term: String, in text: String, from: String.Index? = nil) -> Range<String.Index>? {
        text.range(of: term, options: options, range: from.map { $0..<text.endIndex }, locale: .current)
    }

    func matches(_ text: String) -> Bool {
        !terms.isEmpty && terms.allSatisfy { Self.find($0, in: text) != nil }
    }

    func matches(_ conversation: Conversation) -> Bool {
        matches(conversation.displayTitle) || conversation.items.contains { item in
            (item.kind == .user || item.kind == .agent) && matches(Self.plain(item.summary))
        }
    }

    func run(_ conversations: some Sequence<Conversation>, limit: Int = 200, perConversation: Int = 20) -> Result {
        guard !terms.isEmpty else { return Result() }
        var result = Result()
        for conversation in conversations {
            let title = conversation.displayTitle
            let archived = conversation.archived == true
            var hits: [Hit] = []
            for item in conversation.items.reversed() where item.kind == .user || item.kind == .agent {
                let text = Self.plain(item.summary)
                guard matches(text) else { continue }
                guard hits.count < perConversation else {
                    result.truncated = true
                    break
                }
                let excerpt = snippet(text)
                hits.append(Hit(convId: conversation.id, messageId: item.id, title: title, ts: item.ts, archived: archived,
                    snippet: excerpt.0, highlights: excerpt.1))
            }
            if hits.isEmpty, matches(title) {
                let excerpt = snippet(title)
                hits = [Hit(convId: conversation.id, messageId: nil, title: title, ts: conversation.updatedAt, archived: archived,
                    snippet: excerpt.0, highlights: excerpt.1)]
            }
            guard !hits.isEmpty else { continue }
            hits.sort { $0.ts > $1.ts }
            result.groups.append(Group(convId: conversation.id, title: title, archived: archived, hits: hits))
        }
        result.groups.sort { ($0.hits[0].ts, $1.convId) > ($1.hits[0].ts, $0.convId) }
        var remaining = limit
        for index in result.groups.indices {
            let count = result.groups[index].hits.count
            if count > remaining {
                result.truncated = true
                result.groups[index].hits.removeLast(count - remaining)
            }
            remaining -= result.groups[index].hits.count
        }
        result.groups.removeAll { $0.hits.isEmpty }
        return result
    }

    func snippet(_ text: String) -> (String, [Range<String.Index>]) {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        var start = line.startIndex
        if let first = terms.first, let match = Self.find(first, in: line) {
            var from = match.lowerBound
            var width = 0
            while from > line.startIndex {
                let previous = line.index(before: from)
                width += Self.width(line[previous])
                guard width <= Self.context else { break }
                from = previous
            }
            if from > line.startIndex {
                start = line[from..<match.lowerBound].firstIndex(where: \.isWhitespace).map { line.index(after: $0) } ?? from
            }
        }
        let end = line.index(start, offsetBy: Self.length, limitedBy: line.endIndex) ?? line.endIndex
        var snippet = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > line.startIndex { snippet = "…" + snippet }
        if end < line.endIndex { snippet += "…" }
        return (snippet, highlights(in: snippet))
    }

    static func width(_ character: Character) -> Int {
        (character.unicodeScalars.first?.value ?? 0) >= 0x2E80 ? 2 : 1
    }

    func highlights(in text: String) -> [Range<String.Index>] {
        terms.flatMap { term in
            var ranges: [Range<String.Index>] = []
            var from = text.startIndex
            while from < text.endIndex, let range = Self.find(term, in: text, from: from), !range.isEmpty {
                ranges.append(range)
                from = range.upperBound
            }
            return ranges
        }
        .sorted { $0.lowerBound < $1.lowerBound }
    }
}
