import XCTest

final class JapaneseStreamingTests: XCTestCase {
    @MainActor
    func testGrowingJapaneseReplyBecomesSelectableWithoutLosingItsBlocks() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "japanese-streaming", "-yorozuFinishJapanese", "on", "-followUpBehavior", "steer"]
        app.launch()
        continueAfterFailure = false
        let prefix = "日本語の文章を読みやすく表示します。"
        let streaming = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "The partial reply must wrap through SwiftUI while streaming")
        let completed = app.descendants(matching: .any).matching(NSPredicate(format: "value BEGINSWITH %@", prefix)).firstMatch
        XCTAssertFalse(completed.exists, "The reply must still be streaming before completion")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Japanese reply while growing"
        before.lifetime = .keepAlways
        add(before)

        let field = app.textViews["Message"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText("Continue")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["おすすめ"].waitForExistence(timeout: 15), "Growing deltas must add the table through SwiftUI")
        XCTAssertFalse(completed.exists, "Growing deltas must not complete the reply")
        field.tap()
        field.typeText("Finish")
        app.buttons["Send"].tap()

        XCTAssertTrue(completed.waitForExistence(timeout: 15), "Completion must hand off to the selectable TextKit reply")
        let value = completed.value as? String ?? ""
        XCTAssertTrue(value.contains("確認する項目"))
        XCTAssertTrue(value.contains("printf 日本語"))
        XCTAssertTrue(value.hasSuffix("無理のないサイズを選びましょう。"))
        XCTAssertTrue(app.staticTexts["おすすめ"].exists, "The hosted table must survive completion")
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Japanese reply after completion"
        after.lifetime = .keepAlways
        add(after)
    }
}
