import XCTest

final class ThreadSelectionTests: XCTestCase {
    @MainActor
    func testIPhoneThreadRowOpensChat() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "threads"]
        app.launch()

        let thread = app.buttons["Standup notes. Summarised yesterday's thread."]
        XCTAssertTrue(thread.waitForExistence(timeout: 30))
        thread.tap()
        XCTAssertTrue(app.textViews["Message"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testIPadThreadRowsOpenAndSwitchDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "threads"]
        app.launch()

        let first = app.buttons["Standup notes. Summarised yesterday's thread."]
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        first.tap()
        XCTAssertTrue(app.textViews["Message"].waitForExistence(timeout: 10))

        let second = app.buttons["Invoices. Found the July one in Downloads."]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.tap()
        XCTAssertTrue(app.navigationBars["Invoices"].waitForExistence(timeout: 10))
    }
}
