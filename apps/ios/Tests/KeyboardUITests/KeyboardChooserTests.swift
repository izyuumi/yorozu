import XCTest

/// Offline showcase, no account, relay, or real message. Run on iPhone and iPad with the
/// simulator software keyboard enabled. Check *during* selection, not only after Done.
final class KeyboardChooserTests: XCTestCase {
    @MainActor
    func testChoosingKeepsKeyboardAndDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "chat"]
        app.launch()
        let field = app.textViews["Message"].exists
            ? app.textViews["Message"] : app.textFields["Message"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Keyboard regression draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Model and effort"].tap()
        let panel = app.otherElements["runSettingsPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Opening must not hide keyboard")
        let openShot = XCTAttachment(screenshot: app.screenshot())
        openShot.name = "Chooser open with keyboard"
        openShot.lifetime = .keepAlways
        add(openShot)
        app.buttons["Auto"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Model selection must preserve keyboard")
        panel.swipeUp()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Scrolling choices must preserve keyboard")
        let effort = app.buttons["Low"]
        if !effort.isHittable { panel.swipeUp() }
        effort.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Effort selection must preserve keyboard")
        XCTAssertEqual(app.buttons["Model and effort"].value as? String, "Auto, Low")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(field.value as? String, "Keyboard regression draft")
        field.typeText(" continues")
        XCTAssertEqual(field.value as? String, "Keyboard regression draft continues")
    }

    @MainActor
    func testOpeningWithoutFocusDoesNotSummonKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "chat"]
        app.launch()
        let chooser = app.buttons["Model and effort"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 10))
        chooser.tap()
        XCTAssertTrue(app.otherElements["runSettingsPanel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
}
