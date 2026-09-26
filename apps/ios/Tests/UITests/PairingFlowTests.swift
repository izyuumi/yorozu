import XCTest

/// Offline pairing fixtures never save a code or reach the relay/Keychain.
final class PairingFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testAcceptedManualCodeDismissesAndShowsAsynchronousFailure() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "pairing-connection-failure"]
        app.launch()
        let manual = app.buttons["Enter code manually"]
        XCTAssertTrue(manual.waitForExistence(timeout: 20))
        manual.tap()
        let field = app.textViews["Paste pairing code"].exists
            ? app.textViews["Paste pairing code"] : app.textFields["Paste pairing code"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("offline-test-code")
        app.buttons["Connect"].tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Pair with your Mac"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed,
            "Accepted input must dismiss so the parent can display network progress and failure")
        XCTAssertTrue(app.staticTexts["Couldn’t connect. Generate a new pairing code and try again."]
            .waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pairing asynchronous failure visible"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testScannerOffersManualEntryWithoutCancelling() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "pairing"]
        app.launch()
        let scan = app.buttons["Scan pairing code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 20))
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan pairing code"].waitForExistence(timeout: 20))
        // The simulator cannot scan. The alternative must belong to this presented sheet,
        // rather than the obscured launch screen beneath it.
        let manual = app.buttons["pairing.scanner.manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        XCTAssertTrue(manual.isHittable)
        manual.tap()
        XCTAssertTrue(app.navigationBars["Pair with your Mac"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testInvalidManualCodeKeepsEditableSheetAndShowsError() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "pairing-manual"]
        app.launch()
        let field = app.textViews["Paste pairing code"].exists
            ? app.textViews["Paste pairing code"] : app.textFields["Paste pairing code"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("invalid")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.staticTexts["Not a Yorozu pairing code."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Pair with your Mac"].exists)
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
    }

    @MainActor
    func testLargeTextLandscapeKeepsPairingActionsAndErrorReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "pairing-error",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let error = app.staticTexts["Not a Yorozu pairing code."]
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        let viewport = app.windows.firstMatch.frame
        XCTAssertGreaterThan(viewport.width, viewport.height, "The layout must actually be landscape")
        for _ in 0..<6 {
            if error.isHittable && viewport.contains(error.frame) { break }
            app.swipeUp()
        }
        XCTAssertTrue(error.isHittable && viewport.contains(error.frame),
            "The entire pairing error must be readable at the largest text size")
        let manual = app.buttons["Enter code manually"]
        for _ in 0..<6 {
            if manual.isHittable && viewport.contains(manual.frame) { break }
            app.swipeDown()
        }
        XCTAssertTrue(manual.isHittable && viewport.contains(manual.frame))
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Pairing landscape accessibility frames"
        tree.lifetime = .keepAlways
        add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pairing landscape accessibility text"
        shot.lifetime = .keepAlways
        add(shot)
        manual.tap()
        XCTAssertTrue(app.navigationBars["Pair with your Mac"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testConnectingDisablesNewPairingAttempts() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "pairing-connecting"]
        app.launch()
        let scan = app.buttons["Scan pairing code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 20))
        XCTAssertFalse(scan.isEnabled)
        XCTAssertFalse(app.buttons["Enter code manually"].isEnabled)
        XCTAssertFalse(app.navigationBars["Pair with your Mac"].exists)
    }
}
