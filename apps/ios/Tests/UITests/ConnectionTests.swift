import XCTest

/// What a failing network looks like on screen, against the real relay and Mac sidecar behind a
/// proxy that fails on request (packages/runtime/test-support/wire-harness.mjs). Run through
/// apps/ios/e2e/ui-tests.sh, which starts the harness and passes its control URL; skipped
/// without it. The app keeps its production timing, so these also prove the shipped numbers.
final class ConnectionTests: XCTestCase {
    private var rig: Rig!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        guard let control = ProcessInfo.processInfo.environment["YOROZU_RIG"].flatMap(URL.init(string:)) else {
            throw XCTSkip("run through apps/ios/e2e/ui-tests.sh")
        }
        rig = Rig(control: control)
        try await rig.post("heal")
        app = await XCUIApplication()
    }

    /// A silently dead link is noticed and shown, a brief drop is not, and the link comes back
    /// on its own. Idle, nothing but the ping can tell: up to 40s, then the 5s grace.
    @MainActor
    func testAReconnectingLinkIsShownOnlyWhenItLastsAndClearsItself() async throws {
        try await launchPaired()
        let reconnecting = app.descendants(matching: .any)["Mac connection: Reconnecting"].firstMatch
        try await rig.post("down")
        try await rig.post("heal")
        XCTAssertFalse(reconnecting.waitForExistence(timeout: 7), "A brief drop flickered the status")

        try await rig.post("blackhole")
        XCTAssertTrue(reconnecting.waitForExistence(timeout: 70), "A dead link was never shown")
        try await rig.post("heal")
        XCTAssertTrue(reconnecting.waitForNonExistence(timeout: 70), "The link did not come back by itself")
        XCTAssertEqual(app.buttons["Settings"].value as? String, "Mac connection: Connected")
    }

    /// Messages sent into a dead link say they are unconfirmed, then go through once each, in
    /// order, without the user doing anything.
    @MainActor
    func testMessagesSentIntoADeadLinkConfirmOnceEachWhenItReturns() async throws {
        try await launchPaired()
        try openThread()
        try await rig.post("blackhole")
        send("dead link one")
        send("dead link two")
        // "Confirming" if the sends beat the idle ping to the dead link, "Queued" if they did
        // not: either is honest, and neither may claim delivery.
        let confirming = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["Confirming delivery…", "Queued"])).firstMatch
        XCTAssertTrue(confirming.waitForExistence(timeout: 10), "The messages claim delivery")
        try await rig.post("heal")
        XCTAssertTrue(confirming.waitForNonExistence(timeout: 70), "Delivery never confirmed")
        XCTAssertEqual(bubbles("dead link one"), 1)
        XCTAssertEqual(bubbles("dead link two"), 1)
        let recorded = try await rig.messages().filter { $0.role == "user" && $0.text.hasPrefix("dead link") }.map(\.text)
        XCTAssertEqual(recorded, ["dead link one", "dead link two"])
    }

    /// A message whose receipt never arrives stays "Confirming" rather than claiming delivery.
    /// The app is killed right there and the Mac finishes without it; relaunched, the app shows
    /// that one answer and settles the message, and nothing ran twice.
    @MainActor
    func testALostReceiptSurvivesARelaunchAndSettlesOnce() async throws {
        try await launchPaired()
        try openThread()
        try await rig.post("drop-host")
        send("lost receipt")
        let confirming = app.descendants(matching: .any)["Confirming delivery…"].firstMatch
        XCTAssertTrue(confirming.waitForExistence(timeout: 10))
        XCTAssertFalse(confirming.waitForNonExistence(timeout: 5), "Delivery claimed without a receipt")
        let answered = Date.now + 30
        while try await !rig.messages().contains(where: { $0.role == "agent" && $0.text == "echo: lost receipt" }) {
            guard Date.now < answered else { return XCTFail("The Mac never answered") }
            try await Task.sleep(for: .milliseconds(200))
        }

        app.terminate()
        try await rig.post("heal")
        app.launchArguments = []
        app.launch()
        try waitConnected()
        let thread = app.buttons.matching(NSPredicate(format: "label CONTAINS 'lost receipt'")).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 30), "The thread is gone after relaunch")
        thread.tap()
        XCTAssertTrue(app.textViews["echo: lost receipt"].waitForExistence(timeout: 30), "The answer never arrived")
        XCTAssertTrue(confirming.waitForNonExistence(timeout: 70), "Delivery never settled")
        XCTAssertEqual(bubbles("lost receipt"), 1)
        let recorded = try await rig.messages().filter { $0.text.hasSuffix("lost receipt") }
        XCTAssertEqual(recorded.map(\.role), ["user", "agent"], "Run once, answered once")
    }

    /// A relaunched app is still paired, still has its history, and still talks.
    @MainActor
    func testARelaunchedAppRejoinsWithItsHistory() async throws {
        try await launchPaired()
        try openNewChat()
        send("before relaunch")
        XCTAssertTrue(app.textViews["echo: before relaunch"].waitForExistence(timeout: 30))

        app.terminate()
        app.launchArguments = []
        app.launch()
        try waitConnected()
        XCTAssertFalse(app.navigationBars["Pair with your Mac"].exists)
        let thread = app.buttons.matching(NSPredicate(format: "label CONTAINS 'before relaunch'")).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 30), "The thread is gone after relaunch")
        thread.tap()
        XCTAssertTrue(app.textViews["echo: before relaunch"].waitForExistence(timeout: 30))
        send("after relaunch")
        XCTAssertTrue(app.textViews["echo: after relaunch"].waitForExistence(timeout: 30))
    }

    // MARK: - Steps

    @MainActor
    private func launchPaired() async throws {
        app.launchArguments = ["-yorozuPair", try await rig.pairing()]
        app.launch()
        try waitConnected()
    }

    @MainActor
    private func waitConnected() throws {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "No thread list")
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Mac connection: Connected'"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 45), .completed, "Never connected")
    }

    @MainActor
    private func openNewChat() throws {
        app.buttons["New thread"].firstMatch.tap()
        let yorozu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Yorozu'")).firstMatch
        XCTAssertTrue(yorozu.waitForExistence(timeout: 10), "No Yorozu choice in New thread")
        yorozu.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "No composer in the new chat")
    }

    /// A thread the Mac already has. In a new one, messages rightly wait as "Queued" until the
    /// Mac confirms the thread itself, which would hide what these tests are after.
    @MainActor
    private func openThread() throws {
        try openNewChat()
        send("hello")
        XCTAssertTrue(app.textViews["echo: hello"].waitForExistence(timeout: 30), "The new thread never answered")
    }

    /// How many bubbles say exactly `text`. Each bubble is a text view inside another that
    /// carries it as a value, so only the labelled one is counted.
    @MainActor
    private func bubbles(_ text: String) -> Int {
        app.textViews.matching(NSPredicate(format: "label == %@", text)).count
    }

    @MainActor
    private var composer: XCUIElement {
        app.textViews["Message"].exists ? app.textViews["Message"] : app.textFields["Message"]
    }

    @MainActor
    private func send(_ text: String) {
        composer.tap()
        composer.typeText(text)
        app.buttons["Send"].tap()
        XCTAssertTrue(app.textViews[text].waitForExistence(timeout: 10), "\(text) not in the chat")
    }
}

/// The harness's control port, reachable from the simulator as the Mac's own loopback.
private struct Rig {
    let control: URL

    func post(_ fault: String) async throws {
        var request = URLRequest(url: control.appending(path: fault))
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    func pairing() async throws -> String {
        struct Reply: Decodable { var qr: String }
        return try await get(Reply.self, "pairing").qr
    }

    struct Message: Decodable { var role: String; var text: String }

    /// Every user message and finished answer the Mac recorded.
    func messages() async throws -> [Message] {
        struct Reply: Decodable { var messages: [Message] }
        return try await get(Reply.self, "messages").messages
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        try JSONDecoder().decode(type, from: try await URLSession.shared.data(from: control.appending(path: path)).0)
    }
}
