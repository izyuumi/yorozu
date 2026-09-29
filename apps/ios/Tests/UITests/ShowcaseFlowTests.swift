import XCTest

/// Flows that need no Mac: the showcase seeds this device alone, and what the app sends goes
/// nowhere, so these prove what a tap does on screen, not what the host does with it.
final class ShowcaseFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// User long press copies the entire component; assistant long press keeps native range selection.
    @MainActor
    func testUserLongPressCopiesWholeMessageAndAssistantKeepsTextSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "chat"]
        app.launch()
        let text = "Perfect. Remind me before the next one."
        let user = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 30))
        let actions = XCTAttachment(screenshot: app.screenshot())
        actions.name = "Icon-only message actions"
        actions.lifetime = .keepAlways
        add(actions)
        user.press(forDuration: 1)
        let copy = app.descendants(matching: .any)["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        let composer = app.textViews["Message"]
        composer.tap()
        composer.press(forDuration: 1)
        let paste = app.descendants(matching: .any)["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let pasted = expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: composer)
        wait(for: [pasted], timeout: 10)
        app.swipeDown()
        let assistant = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Yes — the'")).firstMatch
        let timeline = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        for _ in 0..<4 where !assistant.isHittable { timeline.swipeDown() }
        XCTAssertTrue(assistant.isHittable)
        assistant.press(forDuration: 1)
        XCTAssertTrue(app.descendants(matching: .any)["Look Up"].firstMatch.waitForExistence(timeout: 5),
                      "Assistant lost native word selection")
        XCTAssertFalse(app.buttons["Remove from this device"].exists, "Assistant opened whole-message menu")
        let selection = XCTAttachment(screenshot: app.screenshot())
        selection.name = "Assistant native word selection"
        selection.lifetime = .keepAlways
        add(selection)
    }

    @MainActor
    func testOpenClawDraftPickerShowsAvailabilityAndKeepsSelectedChoice() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "channel-model", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let picker = app.buttons["channelModelMenu"]
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        XCTAssertEqual(picker.label, "Model")
        XCTAssertEqual(picker.value as? String, "Default")
        picker.tap()
        let unavailable = app.buttons["Offline model — Provider offline"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertFalse(unavailable.isEnabled)
        let fast = app.buttons["Fast model"]
        XCTAssertTrue(fast.isEnabled)
        fast.tap()
        XCTAssertTrue(fast.isSelected)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertEqual(picker.value as? String, "openclaw/fast")
        picker.tap()
        let defaultModel = app.buttons["Default"]
        XCTAssertTrue(defaultModel.waitForExistence(timeout: 10))
        defaultModel.tap()
        XCTAssertTrue(defaultModel.isSelected)
        XCTAssertFalse(app.staticTexts["How much effort?"].exists)
    }

    /// Answering takes the choices away at once and says the answer is on its way; nothing
    /// is left to tap twice.
    @MainActor
    func testAnsweringAnApprovalCardLeavesItWaitingOnTheHost() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "approval"]
        app.launch()
        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 30), "The approval card did not appear")
        XCTAssertTrue(app.buttons["Decline"].exists)
        approve.tap()
        XCTAssertTrue(app.staticTexts["Answer pending · waiting for host"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.buttons["Decline"].exists)
    }

    /// "Always allow" opens the rule before anything is saved, and backing out leaves the card
    /// still asking.
    @MainActor
    func testAlwaysAllowShowsTheRuleFirstAndCancelKeepsTheCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "card"]
        app.launch()
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30), "The purchase card did not appear")
        more.tap()
        let always = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Always allow'")).firstMatch
        XCTAssertTrue(always.waitForExistence(timeout: 10), "More offers no Always allow")
        always.tap()
        XCTAssertTrue(app.navigationBars["Always allow"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Approve"].waitForExistence(timeout: 10))
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
