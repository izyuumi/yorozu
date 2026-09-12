import Foundation

/// The plain-text rules a bubble needs and a view cannot be trusted with: when a message is too
/// long to read in the thread, what its excerpt is, and how a quoted reply is written down.
///
/// All of it is string in, string out, so the thread, the reader sheet and the tests all agree
/// on the same answer.

/// Past this a message stops being something you read in passing and becomes a document, which
/// is what the reader sheet is for. Either limit alone is enough: a wall of short lines and one
/// enormous paragraph are both the same problem.
let readerCharacterLimit = 1200
let readerLineLimit = 30

/// Whether a message is long enough to be worth offering "Read more" rather than drawn whole.
public func needsReader(_ text: String) -> Bool {
    text.count > readerCharacterLimit || text.components(separatedBy: .newlines).count > readerLineLimit
}

/// What the bubble draws in place of a long message: the opening of it, cut on a line and then
/// on a word, with an ellipsis so the cut is visible rather than looking like the end.
///
/// The cut can leave an unclosed fence or a half-written `**`, which is fine — that is the
/// normal state of a streaming reply and the parser and the inline renderer both already
/// expect it.
public func readerExcerpt(_ text: String) -> String {
    guard needsReader(text) else { return text }
    var excerpt = text.components(separatedBy: .newlines).prefix(readerLineLimit).joined(separator: "\n")
    if excerpt.count > readerCharacterLimit {
        let cut = excerpt.index(excerpt.startIndex, offsetBy: readerCharacterLimit)
        // Back up to the last space, so the excerpt does not end mid-word — unless the whole
        // thing is one unbroken run of characters, in which case the hard cut is all there is.
        let space = excerpt[excerpt.startIndex..<cut].lastIndex(of: " ")
        excerpt = String(excerpt[excerpt.startIndex..<(space ?? cut)])
    }
    return excerpt.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
}

/// A reply with what it is replying to, as one message. The quote goes in as a Markdown
/// blockquote rather than as a field on the wire: every client, and every agent reading the
/// thread back, already understands `>`.
public func quotedMessage(quoting quote: String, body: String) -> String {
    let lines = quote.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
    // A blank line inside a quote stays inside it: `>` alone, not `> `, which would leave
    // trailing whitespace in every quoted message ever sent.
    let quoted = lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    let typed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return typed.isEmpty ? quoted : "\(quoted)\n\n\(typed)"
}

/// The inverse, for drawing one: the quoted text and what was said in reply, or nil and the
/// message unchanged when it is not a quoted reply at all.
public func splitQuote(_ text: String) -> (quote: String?, body: String) {
    var lines = text.components(separatedBy: .newlines)[...]
    var quoted: [String] = []
    while let line = lines.first, line.hasPrefix(">") {
        quoted.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        lines = lines.dropFirst()
    }
    guard !quoted.isEmpty else { return (nil, text) }
    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (quoted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), body)
}

/// A message squeezed onto one line, for the reply chip and anywhere else a whole thread has to
/// fit in a row.
public func snippet(_ text: String, limit: Int = 120) -> String {
    let flat = text.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard flat.count > limit else { return flat }
    return flat.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
}
