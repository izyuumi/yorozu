import XCTest

/// Flows that need no Mac: the showcase seeds this device alone, and what the app sends goes
/// nowhere, so these prove what a tap does on screen, not what the host does with it.
final class ShowcaseFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Answering takes the choices away at once and says the answer is on its way; nothing
    /// is left to tap twice.
    @MainActor
    func testAnsweringAnApprovalCardLeavesItWaitingOnTheHost() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "approval"]
        app.launch()
        let allow = app.buttons["Allow once"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "The approval card did not appear")
        XCTAssertTrue(app.buttons["Don't allow"].exists)
        allow.tap()
        XCTAssertTrue(app.staticTexts["Answer pending · waiting for host"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Allow once"].exists)
        XCTAssertFalse(app.buttons["Don't allow"].exists)
    }

    /// "Always allow" opens the rule before anything is saved, and backing out leaves the card
    /// still asking.
    @MainActor
    func testAlwaysAllowShowsTheRuleFirstAndCancelKeepsTheCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "card"]
        app.launch()
        let always = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Always allow'")).firstMatch
        XCTAssertTrue(always.waitForExistence(timeout: 30), "The purchase card did not appear")
        always.tap()
        XCTAssertTrue(app.navigationBars["Always allow"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Answer pending · waiting for host"].exists)
    }

    /// An archived thread leaves the list for the archive, and restoring it brings it back.
    @MainActor
    func testArchivingAThreadMovesItToTheArchiveAndRestoreBringsItBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "threads"]
        app.launch()
        let row = app.buttons["Invoices. Found the July one in Downloads."]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        // The menu rather than a swipe: a tap on a swipe action can land while it is still
        // sliding in, and then does nothing.
        row.press(forDuration: 1)
        app.buttons["Archive"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "An archived thread stays in the list")

        // The archive is the last thing in the list, and a list draws its rows only once on screen.
        let archive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archived'")).firstMatch
        XCTAssertTrue(scrolledTo(archive, in: app), "No archive after archiving")
        archive.tap()
        XCTAssertTrue(scrolledTo(row, in: app), "The archive does not list the thread")
        row.press(forDuration: 1)
        app.buttons["Restore"].tap()
        XCTAssertTrue(archive.waitForNonExistence(timeout: 10), "The archive outlives its last thread")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "A restored thread is not back in the list")
    }

    /// Scrolls down until `element` is drawn, a few screens at most.
    @MainActor
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        // The list itself, not the app: iOS 26 does not scroll a list for a swipe on the window.
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !element.waitForExistence(timeout: 2) { list.swipeUp() }
        return element.exists
    }
}
