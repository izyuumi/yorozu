import Foundation

final class ComposerCursor {
    private enum Caret {
        case following(NSRange?)
        case insertAt(NSRange)
    }

    private var caret: Caret = .following(nil)

    func track(_ range: NSRange) {
        if case .following = caret { caret = .following(range) }
    }

    func take(within length: Int) -> NSRange? {
        guard case .insertAt(let range) = caret else { return nil }
        guard NSMaxRange(range) <= length else {
            caret = .following(nil)
            return nil
        }
        caret = .following(range)
        return range
    }

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
