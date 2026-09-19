import Foundation
import Testing

@testable import YorozuShared

/// The block parser. Inline spans are Foundation's, so what is worth testing here is the
/// structure it finds — and, just as much, what it refuses to call structure.

@Test func proseIsOneParagraphPerBlankLineAndNothingElse() {
    #expect(markdownBlocks("hello") == [.paragraph("hello")])
    #expect(markdownBlocks("one\n\ntwo") == [.paragraph("one"), .paragraph("two")])
    // A single newline is the author's wrap, not a new block.
    #expect(markdownBlocks("one\ntwo") == [.paragraph("one\ntwo")])
    #expect(markdownBlocks("") == [])
    #expect(markdownBlocks("   \n\n  ") == [])
    // Inline markup is left alone here: it is rendered, not parsed, at this level.
    #expect(markdownBlocks("**bold** and `code`") == [.paragraph("**bold** and `code`")])
}

@Test func headingsNeedTheirSpaceAndKeepTheirLevel() {
    #expect(markdownBlocks("# Title") == [.heading(level: 1, text: "Title")])
    #expect(markdownBlocks("###### Deep") == [.heading(level: 6, text: "Deep")])
    #expect(markdownBlocks("## Totals ##") == [.heading(level: 2, text: "Totals")])
    // Seven is past the end of headings, and a hashtag is not one at all.
    #expect(markdownBlocks("####### Nope") == [.paragraph("####### Nope")])
    #expect(markdownBlocks("#hashtag") == [.paragraph("#hashtag")])
}

@Test func fencesAreVerbatimAndAnUnclosedOneIsStillABlock() {
    #expect(
        markdownBlocks("```swift\nlet x = 1\n```")
            == [.code(language: "swift", text: "let x = 1")]
    )
    #expect(markdownBlocks("```\nplain\n```") == [.code(language: nil, text: "plain")])
    // Nothing inside a fence is Markdown, including what looks like every other block.
    #expect(
        markdownBlocks("```\n# not a heading\n- not a list\n```")
            == [.code(language: nil, text: "# not a heading\n- not a list")]
    )
    // A reply mid-stream has not closed its fence yet, and must still draw as code.
    #expect(markdownBlocks("```js\nconst a =") == [.code(language: "js", text: "const a =")])
    #expect(markdownBlocks("~~~\ntilde\n~~~") == [.code(language: nil, text: "tilde")])
}

@Test func listsGroupTheirOwnKindAndPickUpContinuations() {
    #expect(markdownBlocks("- a\n- b") == [.list(ordered: false, items: ["a", "b"])])
    #expect(markdownBlocks("* a\n+ b") == [.list(ordered: false, items: ["a", "b"])])
    #expect(markdownBlocks("1. first\n2. second") == [.list(ordered: true, items: ["first", "second"])])
    #expect(markdownBlocks("1) first") == [.list(ordered: true, items: ["first"])])
    // Bullets and numbers are two lists, not one with a confused marker.
    #expect(
        markdownBlocks("- a\n1. b")
            == [.list(ordered: false, items: ["a"]), .list(ordered: true, items: ["b"])]
    )
    // An indented line belongs to the item above it.
    #expect(markdownBlocks("- a\n  still a\n- b") == [.list(ordered: false, items: ["a still a", "b"])])
    // A bare hyphen is a rule; `2024-01-01` is prose.
    #expect(markdownBlocks("---") == [.rule])
    #expect(markdownBlocks("2024-01-01") == [.paragraph("2024-01-01")])
}

@Test func aPipeTableNeedsItsSeparatorRowToBeOne() {
    #expect(
        markdownBlocks("| a | b |\n|---|---|\n| 1 | 2 |")
            == [.table(header: ["a", "b"], rows: [["1", "2"]])]
    )
    // Alignment colons are still a separator.
    #expect(
        markdownBlocks("| a | b |\n|:--|--:|\n| 1 | 2 |")
            == [.table(header: ["a", "b"], rows: [["1", "2"]])]
    )
    // Without one, pipes are just characters in a sentence.
    #expect(markdownBlocks("| a | b |\n| 1 | 2 |") == [.paragraph("| a | b |\n| 1 | 2 |")])
    // A table still streaming has a header and no rows yet.
    #expect(markdownBlocks("| a | b |\n|---|---|") == [.table(header: ["a", "b"], rows: [])])
}

@Test func aMixedReplyKeepsEveryBlockInOrder() {
    let reply = """
        Here is what I found.

        ## Steps
        1. Open the file
        2. Run it

        ```sh
        ./run.sh
        ```

        | file | size |
        |------|------|
        | a.txt | 2 KB |
        """
    #expect(
        markdownBlocks(reply) == [
            .paragraph("Here is what I found."),
            .heading(level: 2, text: "Steps"),
            .list(ordered: true, items: ["Open the file", "Run it"]),
            .code(language: "sh", text: "./run.sh"),
            .table(header: ["file", "size"], rows: [["a.txt", "2 KB"]]),
        ]
    )
}

@Test func inlineMarkdownLinksBareAddressesAndUnderlinesEveryLink() {
    let pasted = AttributedString.chatInline("see https://example.com/a?b=1 or mail me@example.com")
    let links = pasted.runs.compactMap(\.link)
    #expect(links.map(\.absoluteString) == ["https://example.com/a?b=1", "mailto:me@example.com"])
    #expect(pasted.runs.filter { $0.link != nil }.allSatisfy { $0.underlineStyle == .single })
    // A written link keeps its own destination; the detector does not relink its text.
    let written = AttributedString.chatInline("[docs](https://docs.example.com)")
    #expect(written.runs.compactMap(\.link).map(\.absoluteString) == ["https://docs.example.com"])
}

@Test func inlineMarkdownNeverThrowsAwayTheTextItCannotParse() {
    #expect(String(AttributedString.chatInline("**bold**").characters) == "bold")
    // Half-written emphasis is what a streaming reply looks like most of the time.
    #expect(String(AttributedString.chatInline("**half").characters) == "**half")
    #expect(String(AttributedString.chatInline("").characters) == "")
    // Inline code keeps its text and gains the monospaced run the view relies on.
    let code = AttributedString.chatInline("run `ls -l` now")
    #expect(String(code.characters) == "run ls -l now")
    #expect(code.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
}
