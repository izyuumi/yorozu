import XCTest

final class ProgressFooterTests: XCTestCase {
    @MainActor
    func testFallbackProgressAppearsBelowLatestQueuedMessage() {
        let app = XCUIApplication()
        app.launchArguments = ["-yorozuShowcase", "fallback-progress"]
        app.launch()

        let latestText = "Also add potatoes and a lemon"
        let latest = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", latestText, latestText)
        ).firstMatch
        let progress = app.staticTexts["Thinking…"]
        XCTAssertTrue(latest.waitForExistence(timeout: 30))
        XCTAssertTrue(progress.waitForExistence(timeout: 30))
        XCTAssertGreaterThanOrEqual(progress.frame.minY, latest.frame.maxY,
            "Progress must remain below the latest queued message")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Fallback progress below queued messages"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
