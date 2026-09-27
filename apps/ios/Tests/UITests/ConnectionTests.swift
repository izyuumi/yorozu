import XCTest
import UIKit

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

    /// The Settings action copies useful connection state without leaking chat content.
    @MainActor
    func testCopiedDiagnosticsExcludeMessageContent() async throws {
        try await launchPaired()
        try openThread()
        let secret = "private diagnostics marker 8f6c"
        send(secret)
        XCTAssertTrue(app.textViews["echo: \(secret)"].waitForExistence(timeout: 30))
        app.navigationBars.buttons["Threads"].tap()
        app.buttons["Settings"].tap()
        let host = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Your Mac")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10), "No host in Settings")
        host.tap()
        let copy = app.buttons["Copy diagnostics"]
        for _ in 0..<6 where !copy.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(copy.isHittable, "Copy diagnostics is unreachable")
        UIPasteboard.general.string = "clipboard sentinel"
        copy.tap()
        app.navigationBars["Connection"].buttons["Settings"].tap()
        app.buttons["Done"].tap()
        let thread = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", secret)).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.tap()
        composer.tap()
        composer.press(forDuration: 1)
        let paste = app.descendants(matching: .any)["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "No Paste action in the composer")
        paste.tap()
        let diagnostics = try XCTUnwrap(composer.value as? String)
        XCTAssertTrue(diagnostics.contains("Yorozu connection diagnostics"))
        XCTAssertTrue(diagnostics.contains("Connection:"))
        XCTAssertTrue(diagnostics.contains("Transport:"))
        XCTAssertTrue(diagnostics.contains("Pending sends:"))
        XCTAssertFalse(diagnostics.contains(secret))
        XCTAssertFalse(diagnostics.contains("127.0.0.1"), "Diagnostics included the relay URL")
    }

    /// A silently dead link is noticed and shown, a brief drop is not, and the link comes back
    /// on its own. Idle, nothing but the ping can tell: up to 40s, then the 5s grace. The
    /// notice is brief and overlays the list without moving its content; Settings stays truthful.
    @MainActor
    func testAReconnectingLinkIsShownOnlyWhenItLastsAndClearsItself() async throws {
        try await launchPaired()
        let notificationAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if notificationAlert.waitForExistence(timeout: 2) { notificationAlert.buttons["Allow"].tap() }
        try openNewChat()
        send("toast anchor")
        XCTAssertTrue(app.textViews["echo: toast anchor"].waitForExistence(timeout: 30))
        app.navigationBars.buttons["Threads"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "toast anchor")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let initialFrame = row.frame
        let toast = app.descendants(matching: .any)["Connection: Reconnecting"].firstMatch
        try await rig.post("down")
        try await rig.post("heal")
        XCTAssertNotEqual(status(becomes: "Reconnecting", within: 7), .completed, "A brief drop flickered the status")
        XCTAssertFalse(toast.exists, "A brief drop showed a toast")

        try await rig.post("blackhole")
        XCTAssertEqual(status(becomes: "Reconnecting", within: 70), .completed, "A dead link was never shown")
        XCTAssertTrue(toast.waitForExistence(timeout: 8), "A sustained interruption showed no toast")
        XCTAssertEqual(row.frame.minY, initialFrame.minY, accuracy: 1, "The toast moved list content")
        XCTAssertEqual(row.frame.height, initialFrame.height, accuracy: 1, "The toast resized list content")
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(identifier: "Connection: Reconnecting").count, 1)
        let shown = XCTAttachment(screenshot: app.screenshot())
        shown.name = "Connection toast over stable list"
        shown.lifetime = .keepAlways
        add(shown)
        XCTAssertTrue(toast.waitForNonExistence(timeout: 12), "Connection toast did not dismiss")
        let persistentStatus = app.buttons["Settings"].value as? String
        XCTAssertTrue(["Mac connection: Reconnecting", "Mac connection: Host isn’t reachable"]
            .contains(persistentStatus), "Dismissing toast cleared persistent status: \(persistentStatus ?? "missing")")
        XCTAssertFalse(toast.waitForExistence(timeout: 3), "Retry showed the same interruption again")
        XCTAssertEqual(row.frame.minY, initialFrame.minY, accuracy: 1)
        try await rig.post("heal")
        XCTAssertEqual(status(becomes: "Connected", within: 70), .completed, "The link did not come back by itself")
        XCTAssertFalse(toast.exists)
        XCTAssertEqual(row.frame.minY, initialFrame.minY, accuracy: 1)
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
        XCTAssertTrue(app.descendants(matching: .any)["Connection: Reconnecting"].firstMatch
            .waitForExistence(timeout: 25), "A send did not probe the dead link before the idle heartbeat")
        let shown = XCTAttachment(screenshot: app.screenshot())
        shown.name = "Connection toast over open chat"
        shown.lifetime = .keepAlways
        add(shown)
        try await rig.post("heal")
        XCTAssertTrue(confirming.waitForNonExistence(timeout: 70), "Delivery never confirmed")
        // Counted once the answer has finished streaming: a chat still redrawing every word can
        // outlast the snapshot a count needs.
        XCTAssertTrue(app.textViews["echo: dead link two"].waitForExistence(timeout: 60),
                      "The second reply answered the preceding turn")
        // UIKit exposes only visible transcript cells at large Dynamic Type sizes.
        let transcript = app.collectionViews.firstMatch
        for _ in 0..<4 where !app.textViews["dead link one"].exists { transcript.swipeDown() }
        XCTAssertEqual(bubbles("dead link one"), 1)
        var sawSecondMessage = false
        var sawFirstReply = false
        for _ in 0..<8 {
            let count = bubbles("dead link two")
            if count > 0 {
                XCTAssertEqual(count, 1)
                sawSecondMessage = true
            }
            sawFirstReply = sawFirstReply || app.textViews["echo: dead link one"].exists
            if sawSecondMessage && sawFirstReply { break }
            let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(sawSecondMessage, "The second message is missing from the chat")
        XCTAssertTrue(sawFirstReply, "The first reply is missing from the chat")
        let recorded = try await rig.messages().filter { $0.text.contains("dead link") }
        XCTAssertEqual(recorded.filter { $0.role == "user" }.map(\.text),
                       ["dead link one", "dead link two"])
        XCTAssertEqual(recorded.filter { $0.role == "agent" }.map(\.text),
                       ["echo: dead link one", "echo: dead link two"])
    }

    /// A message whose receipt never arrives stays "Confirming" rather than claiming delivery.
    /// The app is killed right there and the Mac finishes without it; relaunched, the app shows
    /// that one answer and settles the message, and nothing ran twice.
    @MainActor
    func testALostReceiptSurvivesARelaunchAndSettlesOnce() async throws {
        try await launchPaired()
        try openThread()
        try await rig.post("hold-answer")
        composer.tap()
        composer.typeText("lost receipt")
        // Let the message reach the host before blocking its receipt. Dropping host frames
        // while typing can interrupt pairing first, leaving an honestly queued message.
        try await rig.post("drop-host-after-phone-frame")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.textViews["lost receipt"].waitForExistence(timeout: 10))
        let confirming = app.descendants(matching: .any)["Confirming delivery…"].firstMatch
        XCTAssertTrue(confirming.waitForExistence(timeout: 10))
        XCTAssertFalse(confirming.waitForNonExistence(timeout: 5), "Delivery claimed without a receipt")
        let started = Date.now + 30
        while try await !rig.answerStarted() {
            guard Date.now < started else { return XCTFail("The Mac never started the turn") }
            try await Task.sleep(for: .milliseconds(200))
        }

        app.terminate()
        try await rig.post("release-answer")
        let answered = Date.now + 30
        while try await !rig.messages().contains(where: { $0.role == "agent" && $0.text == "echo: lost receipt" }) {
            guard Date.now < answered else { return XCTFail("The Mac never answered") }
            try await Task.sleep(for: .milliseconds(200))
        }
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
        let starts = try await rig.answerStarts()
        XCTAssertEqual(starts, 1, "The provider ran the same turn twice")
    }

    /// A relaunched app restores the open chat and unsent text without opening the keyboard;
    /// the restored draft can still be sent through the real host connection.
    @MainActor
    func testARelaunchedAppRejoinsWithItsHistory() async throws {
        try await launchPaired()
        try openNewChat()
        send("before relaunch")
        XCTAssertTrue(app.textViews["echo: before relaunch"].waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("unsent after relaunch")
        XCTAssertEqual(composer.value as? String, "unsent after relaunch")

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "Relaunch did not restore the open chat")
        XCTAssertEqual(composer.value as? String, "unsent after relaunch", "Relaunch lost the draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10),
            "Ordinary relaunch opened the keyboard")
        XCTAssertTrue(app.textViews["echo: before relaunch"].waitForExistence(timeout: 30))
        XCTAssertEqual(composer.value as? String, "unsent after relaunch")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.textViews["echo: unsent after relaunch"].waitForExistence(timeout: 30))
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
    private func status(becomes state: String, within seconds: TimeInterval) -> XCTWaiter.Result {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Mac connection: \(state)"), object: app.buttons["Settings"])
        return XCTWaiter.wait(for: [expectation], timeout: seconds)
    }

    @MainActor
    private func waitConnected() throws {
        // A relaunch reopens the chat that was open, so the list may be one step back.
        let back = app.navigationBars.buttons["Threads"]
        if back.waitForExistence(timeout: 5) { back.tap() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "No thread list")
        XCTAssertEqual(status(becomes: "Connected", within: 45), .completed, "Never connected")
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

    func answerStarted() async throws -> Bool {
        struct Reply: Decodable { var started: Bool }
        return try await get(Reply.self, "answer-started").started
    }

    func answerStarts() async throws -> Int {
        struct Reply: Decodable { var count: Int }
        return try await get(Reply.self, "answer-started").count
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        try JSONDecoder().decode(type, from: try await URLSession.shared.data(from: control.appending(path: path)).0)
    }
}
