import XCTest

/// Offline showcase, no account, relay, or real message. Run on iPhone and iPad with the
/// simulator software keyboard enabled. Check *during* selection, not only after dismissal.
///
/// Every wait is bounded but generous. A hosted CI simulator has been seen running the
/// no-focus test 17x slower than usual (280 s against 16 s), which carried a keyboard that
/// normally shows in a second or two past the old 15–20 s waits. A healthy simulator never
/// reaches any of these limits, so they cost nothing there.
final class KeyboardChooserTests: XCTestCase {
    /// How long one step may take before the test gives up on it.
    private let step: TimeInterval = 60

    override func setUp() {
        super.setUp()
        // Stop at the first failure. Carrying on drives every later tap and query into an app
        // that is not in the expected state; on a slow simulator that turned one failure into
        // a seven-minute test whose CI log named no assertion at all.
        continueAfterFailure = false
    }

    @MainActor
    func testChoosingKeepsKeyboardAndDraft() throws {
        let app = launchChat()
        let field = composerField(in: app)
        field.tap()
        // `typeText` fails outright while the field has yet to take focus; wait for the
        // keyboard the tap summons rather than typing into that gap.
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: step),
            "Tapping the field must show the software keyboard"
        )
        field.typeText("Keyboard regression draft")
        expectValue(field, "Keyboard regression draft")
        app.buttons["Model and effort"].tap()
        XCTAssertTrue(app.buttons["Auto"].waitForExistence(timeout: step))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Opening must not hide keyboard")
        let openShot = XCTAttachment(screenshot: app.screenshot())
        openShot.name = "Native chooser with keyboard"
        openShot.lifetime = .keepAlways
        add(openShot)
        app.buttons["Auto"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Model selection must preserve keyboard")
        app.buttons["Model and effort"].tap()
        let effort = app.buttons["Low"]
        XCTAssertTrue(effort.waitForExistence(timeout: step))
        effort.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Effort selection must preserve keyboard")
        expectValue(app.buttons["Model and effort"], "Auto, Low")
        expectValue(field, "Keyboard regression draft")
        field.typeText(" continues")
        expectValue(field, "Keyboard regression draft continues")
    }

    @MainActor
    func testOpeningWithoutFocusDoesNotSummonKeyboard() {
        let app = launchChat()
        let chooser = app.buttons["Model and effort"]
        chooser.tap()
        XCTAssertTrue(app.buttons["Auto"].waitForExistence(timeout: step))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Auto"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    /// Launches into the seeded chat and waits until its composer bar is on screen, so every
    /// query after this is asked of the chat rather than of a launch still in progress.
    @MainActor
    private func launchChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "chat"]
        app.launch()
        XCTAssertTrue(
            app.buttons["Model and effort"].waitForExistence(timeout: step),
            "The showcase chat did not appear after launch"
        )
        return app
    }

    /// The message field: a `UITextView` on iOS today, with the text-field branch kept for a
    /// composer that goes back to SwiftUI's `TextField`. Decided only once the chat is on
    /// screen (see ``launchChat()``), so a slow launch cannot make the one-shot `exists` pick
    /// the query that never matches and fail every step that follows.
    @MainActor
    private func composerField(in app: XCUIApplication) -> XCUIElement {
        let field = app.textViews["Message"].exists
            ? app.textViews["Message"] : app.textFields["Message"]
        XCTAssertTrue(field.waitForExistence(timeout: step), "No composer field in the chat")
        return field
    }

    /// Waits, bounded by `step`, for `element.value` to read `value`. SwiftUI publishes a
    /// selection to the accessibility tree a run-loop turn after the tap; reading it in the
    /// same instant is a race that only a slow simulator loses.
    @MainActor
    private func expectValue(
        _ element: XCUIElement, _ value: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element
        )
        if XCTWaiter.wait(for: [settled], timeout: step) != .completed {
            XCTFail(
                "Expected value \"\(value)\", found \(String(describing: element.value))",
                file: file, line: line
            )
        }
    }
}
