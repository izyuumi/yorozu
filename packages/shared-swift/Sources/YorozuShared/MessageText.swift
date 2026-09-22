import Foundation

/// The plain-text rules a bubble needs and a view cannot be trusted with: when a message is too
/// long to read in the thread and what its excerpt is.
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
    readerExcerpt(text) != text
}

/// What the bubble draws in place of a long message: its opening lines. The cut lands only
/// between lines, never inside one — a line that is on screen is on screen whole, and the
/// "Read more" button under it is what says there is more, so no ellipsis is written into the
/// text. A single line is never cut, however long, since half a line is worse than a long one.
///
/// The cut can leave an unclosed fence, which is fine — that is the normal state of a
/// streaming reply and the parser already expects it.
public func readerExcerpt(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var kept: [String] = []
    var count = 0
    for line in lines.prefix(readerLineLimit) {
        count += line.count + 1
        if count > readerCharacterLimit, !kept.isEmpty { break }
        kept.append(line)
    }
    guard kept.count < lines.count else { return text }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
