import Foundation
import Testing

@Suite struct ComposerCursorTests {
    @Test func shrinkingTextBeforeRestorationResumesCaretTracking() {
        let cursor = ComposerCursor()
        var text = "hello world"
        cursor.track(NSRange(location: 5, length: 0))
        cursor.insert("dictated", into: &text)

        text = "hi"
        #expect(cursor.take(within: 2) == nil)
        cursor.track(NSRange(location: 1, length: 0))
        cursor.insert("X", into: &text)

        #expect(text == "h X i")
    }

    @Test func invalidRestorationWithoutANewCaretInsertsAtTheEnd() {
        let cursor = ComposerCursor()
        var text = "hello world"
        cursor.track(NSRange(location: 5, length: 0))
        cursor.insert("dictated", into: &text)
        text = "hi"
        #expect(cursor.take(within: 2) == nil)

        text = "hello again"
        cursor.insert("X", into: &text)

        #expect(text == "hello again X")
    }

    @Test func insertsAtTheCaretWithLatinSpacing() {
        let cursor = ComposerCursor()
        var text = "helloworld"
        cursor.track(NSRange(location: 5, length: 0))

        cursor.insert("X", into: &text)

        #expect(text == "hello X world")
    }

    @Test func insertsAtTheEndWithoutACaret() {
        let cursor = ComposerCursor()
        var text = "hello"

        cursor.insert("world", into: &text)

        #expect(text == "hello world")
    }

    @Test func insertsAfterASelectionWithoutReplacingIt() {
        let cursor = ComposerCursor()
        var text = "hello world"
        cursor.track(NSRange(location: 0, length: 5))

        cursor.insert("X", into: &text)

        #expect(text == "hello X world")
    }

    @Test func secondDictationFollowsTheFirst() {
        let cursor = ComposerCursor()
        var text = "hello world"
        cursor.track(NSRange(location: 5, length: 0))

        cursor.insert("one", into: &text)
        cursor.insert("two", into: &text)

        #expect(text == "hello one two world")
    }

    @Test func restoresThePostInsertCaretOnce() {
        let cursor = ComposerCursor()
        var text = "hello world"
        cursor.track(NSRange(location: 5, length: 0))
        cursor.insert("X", into: &text)

        #expect(cursor.take(within: (text as NSString).length) == NSRange(location: 7, length: 0))
        #expect(cursor.take(within: (text as NSString).length) == nil)
        cursor.insert("Y", into: &text)
        #expect(text == "hello X Y world")
    }

    @Test func ignoresCaretTrackingUntilRestoration() {
        let cursor = ComposerCursor()
        var text = "hello world"
        cursor.track(NSRange(location: 5, length: 0))
        cursor.insert("X", into: &text)
        cursor.track(NSRange(location: 0, length: 0))

        #expect(cursor.take(within: (text as NSString).length) == NSRange(location: 7, length: 0))
        cursor.track(NSRange(location: 0, length: 0))
        cursor.insert("Y", into: &text)
        #expect(text == "Y hello X world")
    }
}
