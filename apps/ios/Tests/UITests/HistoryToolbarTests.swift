import XCTest

/// Exact-class-only, offline native acceptance for the secretary/history boundary.
/// Uses ShowcaseTransport and an isolated simulator; never pairs or sends a message.
final class HistoryToolbarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor func testHistorySearchNavigationAndActions() { verifyHistory(accessibility: false) }
    @MainActor func testHistoryToolbarAtAccessibilitySize() { verifyHistory(accessibility: true) }

    @MainActor private func verifyHistory(accessibility: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "threads", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let history = app.buttons["secretary-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 20), app.debugDescription)
        history.tap()
        let returnButton = app.buttons["secretary-return"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 10), app.debugDescription)
        let navigation = app.navigationBars["Threads"].firstMatch
        XCTAssertTrue(navigation.exists, app.debugDescription)
        XCTAssertGreaterThanOrEqual(navigation.frame.minY, returnButton.frame.maxY,
                                    "Return header must not cover the native history bar")
        let settings = app.buttons["Settings"].firstMatch
        let newThread = app.buttons["New thread"].firstMatch
        XCTAssertTrue(settings.isHittable, app.debugDescription)
        XCTAssertTrue(newThread.isHittable, app.debugDescription)
        capture(app, accessibility ? "History accessibility toolbar" : "History toolbar")
        if accessibility {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.isHittable, app.debugDescription)
            search.tap()
            search.typeText("Standup")
            XCTAssertEqual(search.value as? String, "Standup")
            capture(app, "History accessibility search")
            dismissSearch(app, search: search)
            settings.tap()
            XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["Done"].firstMatch.tap()
            returnButton.tap()
            XCTAssertTrue(history.waitForExistence(timeout: 5))
            return
        }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("Standup")
        XCTAssertEqual(search.value as? String, "Standup")
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Standup notes.")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "History search results")
        dismissSearch(app, search: search)
        let thread = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Standup notes.")).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5), app.debugDescription)
        thread.tap()
        XCTAssertTrue(app.textViews["Message"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars["Standup notes"].waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "History existing thread")
        let threadBack = app.navigationBars.buttons["Threads"].firstMatch
        if threadBack.exists { threadBack.tap() }
        else { XCTAssertTrue(search.exists, app.debugDescription) }
        settings.tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "History settings")
        app.buttons["Done"].firstMatch.tap()
        if newThread.exists { newThread.tap() }
        else {
            let newSession = app.buttons["New session"].firstMatch
            XCTAssertTrue(newSession.isHittable, app.debugDescription)
            newSession.tap()
        }
        XCTAssertTrue(app.textViews["Message"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars["New chat"].waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "History new thread")
        let back = app.navigationBars.buttons["Threads"].firstMatch
        if back.exists { back.tap() }
        else {
            // Regular width keeps history in the split sidebar instead of pushing it.
            XCTAssertTrue(search.exists, app.debugDescription)
        }
        XCTAssertTrue(returnButton.isHittable, app.debugDescription)
        returnButton.tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor private func dismissSearch(_ app: XCUIApplication, search: XCUIElement) {
        // iOS 27 exposes the native search dismissal as Close, older bars as Cancel.
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        if close.exists { close.tap() }
        else {
            // iPad sidebar search stays in place instead of presenting a close control.
            let clear = search.buttons["Clear text"]
            XCTAssertTrue(clear.isHittable, app.debugDescription)
            clear.tap()
            if app.keyboards.firstMatch.exists {
                let hideKeyboard = app.buttons["Hide keyboard"].firstMatch
                XCTAssertTrue(hideKeyboard.isHittable, app.debugDescription)
                hideKeyboard.tap()
            }
            XCTAssertFalse(app.keyboards.firstMatch.exists)
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
