import Foundation
import SwiftUI

/// Finding something inside one thread. The matching is here rather than in the view so that the
/// count in the toolbar, the highlight in the bubble and the message the arrows scroll to are
/// all the same list of hits read three ways.

/// One occurrence of the search term, in the message it was found in.
public struct SearchHit: Equatable, Sendable, Identifiable {
    public let eventId: String
    /// Which occurrence within that message this is, so two hits in one bubble are two hits.
    public let occurrence: Int
    public var id: String { "\(eventId)#\(occurrence)" }
}

/// Carries list-search intent into the transcript without changing thread identity.
public struct ThreadSearchRequest: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let threadId: String
    public let query: String

    public init(threadId: String, query: String) {
        self.threadId = threadId
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Both result sections and their empty state use this single partition.
public struct ThreadSearchResults {
    public let threads: [ThreadSummary]
    public let messages: [ThreadSummary]
    public var isEmpty: Bool { threads.isEmpty && messages.isEmpty }

    public init(threads: [ThreadSummary], query: String, messageText: (String) -> String) {
        var metadata: [ThreadSummary] = []
        var content: [ThreadSummary] = []
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            for thread in threads.sorted(by: { $0.lastActivity > $1.lastActivity }) {
                if threadMatches(thread, query: needle) { metadata.append(thread) }
                else if !searchRanges(in: messageText(thread.id), term: needle).isEmpty { content.append(thread) }
            }
        }
        self.threads = metadata
        self.messages = content
    }
}

/// Every occurrence of `term` in `text`, left to right and non-overlapping. Case- and
/// diacritic-insensitive, which is what anyone typing into a search field means.
public func searchRanges(in text: String, term: String) -> [Range<String.Index>] {
    let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    var ranges: [Range<String.Index>] = []
    var start = text.startIndex
    while start < text.endIndex,
        let found = text.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: start..<text.endIndex
        )
    {
        ranges.append(found)
        // A match can be empty under diacritic folding; stepping on is what stops the loop.
        start = found.isEmpty ? text.index(after: found.lowerBound) : found.upperBound
    }
    return ranges
}

/// The thread's hits in reading order: what the arrows step through and the count counts.
public func searchHits(in events: [YorozuEvent], term: String) -> [SearchHit] {
    events.flatMap { event -> [SearchHit] in
        guard case .message(let data) = event.payload else { return [] }
        return searchRanges(in: data.text, term: term).indices.map {
            SearchHit(eventId: event.id, occurrence: $0)
        }
    }
}

extension AttributedString {
    /// The same text with every hit given a background. Applied after the inline Markdown has
    /// been parsed, so a match is highlighted where the reader sees it rather than where it sat
    /// in the source — `**total**` highlights the word, not the asterisks.
    public func highlighting(_ term: String) -> AttributedString {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return self }
        // Ranges first, then the writes: mutating while walking is what invalidates the walk.
        var ranges: [Range<AttributedString.Index>] = []
        var start = startIndex
        while start < endIndex,
            let found = self[start..<endIndex].range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        {
            ranges.append(found)
            start = found.isEmpty ? characters.index(after: found.lowerBound) : found.upperBound
        }
        var highlighted = self
        for range in ranges {
            highlighted[range].backgroundColor = .yellow.opacity(0.45)
        }
        return highlighted
    }
}

extension EnvironmentValues {
    @Entry public var threadSearchRequest: ThreadSearchRequest? = nil
    /// The thread's current search term, handed down rather than passed through every view
    /// between the search field and the run of text a hit is inside.
    @Entry public var searchHighlight: String = ""
}
