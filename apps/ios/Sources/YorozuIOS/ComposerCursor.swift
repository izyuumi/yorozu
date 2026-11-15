import Foundation

/// The composer's caret, kept outside the text view so dictated text lands where the caret was, even though
/// the voice bar replaced the text view meanwhile; a second dictation goes after the first.
final class ComposerCursor {
    private enum Caret {
        case following(NSRange?)
        case insertAt(NSRange)
    }

    private var caret: Caret = .following(nil)

    func track(_ range: NSRange) {
        if case .following = caret { caret = .following(range) }
    }

    /// The caret to restore after an insertion, once.
    func take(within length: Int) -> NSRange? {
        guard case .insertAt(let range) = caret else { return nil }
        guard NSMaxRange(range) <= length else {
            caret = .following(nil)
            return nil
        }
        caret = .following(range)
        return range
    }

    /// Inserts `piece` at the caret (the end if none, after any selection, so nothing typed is replaced), spaced
    /// from a neighboring Latin word, and moves the caret after it.
    func insert(_ piece: String, into text: inout String) {
        let range: NSRange?
        switch caret {
        case .following(let current): range = current
        case .insertAt(let current): range = current
        }
        let current = text as NSString
        var at = NSRange(location: range.map(NSMaxRange) ?? current.length, length: 0)
        if at.location > current.length { at = NSRange(location: current.length, length: 0) }
        let before = at.location > 0 ? current.substring(with: NSRange(location: at.location - 1, length: 1)).first : nil
        let after = at.location < current.length ? current.substring(with: NSRange(location: at.location, length: 1)).first : nil
        let lead = if let before, !before.isWhitespace, before.isASCII || piece.first?.isASCII == true { " " } else { "" }
        let trail = if let after, after.isLetter || after.isNumber, after.isASCII || piece.last?.isASCII == true { " " } else { "" }
        let spaced = lead + piece + trail
        text = current.replacingCharacters(in: at, with: spaced)
        caret = .insertAt(NSRange(location: at.location + (spaced as NSString).length, length: 0))
    }
}
