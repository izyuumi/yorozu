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

    /// An archived thread leaves the live list, restores from Settings, then returns to it.
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

        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archived'")).firstMatch.exists)
        app.buttons["Settings"].tap()
        let archive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archived threads'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "No archive in Settings after archiving")
        archive.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The archive does not list the thread")
        row.swipeLeft()
        let restore = app.buttons["Restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "Swipe did not reveal Restore")
        restore.tap()
        // Restoring the last thread takes the Settings row away, and the archive may leave with it.
        let done = app.buttons["Done"]
        if !done.waitForExistence(timeout: 3) { app.navigationBars["Archived threads"].buttons["Settings"].tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 10), "No way back out of Settings")
        done.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "A restored thread is not back in the list")
    }

    /// A picture opened full screen closes by being dragged down, with no button involved.
    @MainActor
    func testDraggingAPictureDownClosesTheViewer() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "images-viewer"]
        app.launch()
        let viewer = app.navigationBars["kitchen.jpg"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 30), "The picture viewer did not open")
        app.swipeDown()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 10), "Dragging the picture down left the viewer open")
    }

    /// A real drag, rather than only the scroll intent model, must reveal the return control.
    @MainActor
    func testReadingOlderContentCanReturnToLatest() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "chat"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Weeknight dinners"].waitForExistence(timeout: 30))

        let timeline = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let newest = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Perfect. Remind me before the next one.")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        XCTAssertTrue(newest.frame.intersects(timeline.frame), "Conversation did not start at latest")
        let latest = app.buttons["Scroll to bottom"]
        XCTAssertFalse(latest.exists, "Return control appeared while already at latest")
        timeline.swipeDown()
        XCTAssertTrue(latest.waitForExistence(timeout: 10), "Reading upward did not reveal Latest")
        let older = XCTAttachment(screenshot: app.screenshot())
        older.name = "Reading older content"
        older.lifetime = .keepAlways
        add(older)

        latest.tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        XCTAssertTrue(latest.waitForNonExistence(timeout: 10))
        XCTAssertTrue(newest.frame.intersects(timeline.frame), "Latest did not return to the newest message")
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "Returned to latest"
        returned.lifetime = .keepAlways
        add(returned)

        // Leaving while reading history must not make the next ordinary open restore it.
        for title in ["Invoices", "Weeknight dinners", "Invoices", "Weeknight dinners"] {
            timeline.swipeDown()
            XCTAssertTrue(latest.waitForExistence(timeout: 10))
            let back = app.navigationBars.buttons["Threads"]
            if back.exists { back.tap() }
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ".")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))
            XCTAssertTrue(newest.waitForExistence(timeout: 10))
            XCTAssertTrue(newest.frame.intersects(timeline.frame), "Reopening restored stale history")
            XCTAssertFalse(latest.exists, "Reopening did not settle at latest")
        }
    }
}
