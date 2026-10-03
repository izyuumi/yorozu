import CoreText
import UIKit
import XCTest
@testable import YorozuShared

/// Run on iOS: completed replies use TextKit here, not the Mac's SwiftUI renderer.
final class JapaneseReplyTests: XCTestCase {
    @MainActor
    func testWrappedJapaneseGlyphsDoNotOverlapBeforeFollowingMarkdownBlocks() {
        let japanese = String(repeating: "日本語の文章を読みやすく表示します。新しい部屋でもこのタイプを選べます。", count: 4)
        let mixed = String(repeating: "**日本語とLatin**、2.2kWや絵文字🌸、`printf 日本語`を表示します。", count: 4)
        for font in ReplyFont.allCases {
            for width: CGFloat in [180, 280] {
                for text in [japanese, mixed, japanese + "\n" + japanese] {
                    let blocks: [MarkdownBlock] = [
                        .paragraph(text),
                        .heading(level: 2, text: japanese),
                        .list(ordered: false, items: [text, text]),
                        .list(ordered: true, items: [text, text]),
                        .table(header: ["部屋", "おすすめ"], rows: [["洋室", "小さいモデル"]]),
                        .code(language: "sh", text: "printf 日本語"),
                        .rule,
                        .paragraph(text),
                    ]
                    let view = ReplyTextView()
                    view.isEditable = false
                    view.isScrollEnabled = false
                    view.textContainerInset = .zero
                    view.textContainer.lineFragmentPadding = 0
                    view.show(blocks, highlight: "", style: ProseStyle(font: font, ink: .label, tint: .systemRed))
                    view.measureBlocks(width: width)
                    let size = view.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
                    view.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
                    view.layoutIfNeeded()
                    let layout = view.layoutManager
                    layout.ensureLayout(for: view.textContainer)
                    var previousInk: CGRect?
                    var lines = 0
                    layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, glyphs, _ in
                        XCTAssertFalse(rect.isEmpty, "All reply lines must fit at the measured height")
                        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                        let content = view.attributedText.attributedSubstring(from: chars)
                        if content.attribute(.attachment, at: 0, effectiveRange: nil) != nil {
                            previousInk = nil
                            return
                        }
                        // Core Text supplies fallback glyph outlines independently of
                        // TextKit's line rectangles. Rectangles alone missed this bug.
                        let line = CTLineCreateWithAttributedString(content)
                        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                        guard !ink.isEmpty else { return }
                        let baseline = rect.minY + layout.location(forGlyphAt: glyphs.location).y
                        let positioned = CGRect(x: ink.minX, y: baseline - ink.maxY, width: ink.width, height: ink.height)
                        if let previousInk {
                            XCTAssertGreaterThanOrEqual(positioned.minY, previousInk.maxY,
                                "\(font) at \(width)pt: adjacent glyph outlines overlap")
                        }
                        // TextKit rounds baselines to pixels; Core Text outlines are unrounded.
                        XCTAssertGreaterThanOrEqual(positioned.minY, -0.5, "The first line must not clip above the reply")
                        XCTAssertLessThanOrEqual(positioned.maxY, size.height + 0.5, "The final line must fit below the reply")
                        previousInk = positioned
                        lines += 1
                    }
                    XCTAssertGreaterThan(lines, 10, "The fixture must exercise wrapping")
                }
            }
        }
    }
}
