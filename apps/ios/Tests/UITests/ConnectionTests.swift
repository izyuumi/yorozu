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

    /// Search downloaded history while the host is unreachable; an older match stays
    /// available and its limited scope is stated before the connection recovers. Recovery searches
    /// host history without replacing the query or duplicating that downloaded match.
    @MainActor
    func testOfflineSearchShowsDownloadedHistoryAndKeepsItsQuery() async throws {
        try await launchPaired()
        try openNewChat()
        send("ordinary title")
        XCTAssertTrue(app.textViews["echo: ordinary title"].waitForExistence(timeout: 30))
        send("search marker 74c9")
        XCTAssertTrue(app.textViews["echo: search marker 74c9"].waitForExistence(timeout: 30))
        for index in 0..<6 {
            let latest = "newer unrelated answer \(index)"
            send(latest)
            XCTAssertTrue(app.textViews["echo: \(latest)"].waitForExistence(timeout: 30))
        }
        let match = app.textViews["search marker 74c9"]
        XCTAssertFalse(match.exists, "Search fixture must put the older match outside the visible timeline")
        app.navigationBars.buttons["Threads"].tap()

        try await rig.post("down")
        XCTAssertEqual(status(becomes: "Reconnecting", within: 15), .completed)
        app.collectionViews.firstMatch.swipeDown()
        let search = app.searchFields["Search threads"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Thread search is unreachable offline")
        search.tap()
        search.typeText("74c9")
        XCTAssertTrue(app.staticTexts["Downloaded conversations only"].waitForExistence(timeout: 3))
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'search marker 74c9'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3), "Downloaded older message is missing offline")
        result.tap()
        XCTAssertTrue(match.waitForExistence(timeout: 10),
                      "Selecting an older result did not bring its matching message into the visible timeline")
        app.buttons.matching(NSPredicate(format: "label ==[c] 'close'")).firstMatch.tap()
        app.navigationBars.buttons["Threads"].tap()
        app.collectionViews.firstMatch.swipeDown()
        XCTAssertEqual(search.value as? String, "74c9", "Returning lost the search context")
        XCTAssertTrue(result.exists)

        try await rig.post("heal")
        XCTAssertEqual(status(becomes: "Connected", within: 70), .completed)
        XCTAssertTrue(app.staticTexts["All host histories searched"].waitForExistence(timeout: 10),
                      "The offline query was not searched on the host after recovery")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS 'search marker 74c9'")).count, 1,
                       "Host search duplicated the downloaded result")
        XCTAssertEqual(search.value as? String, "74c9", "Host results replaced the search query")
    }

    /// Two real hosts contribute one downloaded match each. Losing one host keeps both results
    /// visible while the scope names the mixed availability; recovery merges host history.
    @MainActor
    func testMixedHostSearchKeepsResultsAndContext() async throws {
        let second = try XCTUnwrap(ProcessInfo.processInfo.environment["YOROZU_RIG2"].flatMap(URL.init(string:)))
        let rig2 = Rig(control: second)
        try await rig2.post("heal")
        let marker = "mixed search marker 8f4a"
        let secondPair = try await rig2.pairing()
        let secondID = try XCTUnwrap(URLComponents(string: secondPair)?.queryItems?
            .first(where: { $0.name == "key" })?.value)
        addTeardownBlock { [weak self] in
            guard let self else { return }
            self.app.terminate()
            self.app.launchArguments = ["-yorozuRemoveHost", secondID]
            self.app.launch()
            try self.waitConnected()
            self.app.terminate()
        }
        app.launchArguments = ["-yorozuPair", try await rig.pairing(),
                               "-yorozuPairSecond", secondPair,
                               "-yorozuSend", marker]
        app.launch()
        for host in [rig!, rig2] {
            let deadline = Date.now + 60
            while try await !host.messages().contains(where: { $0.role == "agent" && $0.text == "echo: \(marker)" }) {
                guard Date.now < deadline else { return XCTFail("A host did not answer the search fixture") }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        // The debug auto-send hook creates a fresh thread on every pairing. Relaunch without
        // that hook before faulting a host, so a reconnect cannot change the fixture itself.
        app.terminate()
        app.launchArguments = []
        app.launch()
        let back = app.navigationBars.buttons["Threads"]
        if back.waitForExistence(timeout: 5) { back.tap() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "No thread list after relaunch")
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "2 of 2 hosts connected"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 45), .completed,
                       "Both hosts did not reconnect before search")
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        list.swipeDown()
        let search = app.searchFields["Search threads"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("8f4a")
        let matches = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker))
        let both = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: matches)
        XCTAssertEqual(XCTWaiter.wait(for: [both], timeout: 45), .completed,
                       "One host's downloaded result is missing")
        XCTAssertTrue(app.staticTexts["All host histories searched"].waitForExistence(timeout: 30))
        XCTAssertEqual(matches.count, 2, "Host results duplicated downloaded matches")

        try await rig2.post("down")
        XCTAssertTrue(app.staticTexts["Downloaded conversations, cached and available host results"]
            .waitForExistence(timeout: 20), "Mixed host availability was not stated truthfully")
        XCTAssertEqual(matches.count, 2, "Disconnect hid a downloaded match")
        let anchor = matches.firstMatch.frame.minY
        try await rig2.post("heal")
        XCTAssertTrue(app.staticTexts["All host histories searched"].waitForExistence(timeout: 70))
        XCTAssertEqual(matches.count, 2, "Recovery duplicated a match")
        XCTAssertEqual(matches.firstMatch.frame.minY, anchor, accuracy: 2,
                       "Host results moved the visible search row")
        matches.firstMatch.tap()
        XCTAssertTrue(app.textViews[marker].waitForExistence(timeout: 10),
                      "Search result did not open its matching message")
        let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'close'")).firstMatch
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let threads = app.navigationBars.buttons["Threads"]
        XCTAssertTrue(threads.waitForExistence(timeout: 5), "Closing in-thread search did not restore navigation")
        threads.tap()
        list.swipeDown()
        XCTAssertEqual(search.value as? String, "8f4a", "Back navigation lost the search query")
        XCTAssertEqual(matches.count, 2, "Back navigation lost the search results")
    }

    /// Pre-pairing host history is absent from routine sync. Local search cannot see it;
    /// recovery must discover it, then backfill and open its older matching message.
    @MainActor
    func testHostOnlySearchResultOpensItsMatchingMessage() async throws {
        let third = try XCTUnwrap(ProcessInfo.processInfo.environment["YOROZU_RIG3"].flatMap(URL.init(string:)))
        let host = Rig(control: third)
        try await host.post("heal")
        try await host.post("seed-search")
        let pairing = try await host.pairing()
        let hostID = try XCTUnwrap(URLComponents(string: pairing)?.queryItems?
            .first(where: { $0.name == "key" })?.value)
        addTeardownBlock { [weak self] in
            guard let self else { return }
            self.app.terminate()
            self.app.launchArguments = ["-yorozuRemoveHost", hostID]
            self.app.launch()
            try self.waitConnected()
            self.app.terminate()
        }
        app.launchArguments = ["-yorozuPair", try await rig.pairing(), "-yorozuPairSecond", pairing]
        app.launch()
        let back = app.navigationBars.buttons["Threads"]
        if back.waitForExistence(timeout: 5) { back.tap() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "2 of 2 hosts connected"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 45), .completed)
        try await host.post("down")
        app.collectionViews.firstMatch.swipeDown()
        let search = app.searchFields["Search threads"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("6e72")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "host-only marker 6e72")).firstMatch
        XCTAssertTrue(app.staticTexts["Downloaded conversations and available host history"]
            .waitForExistence(timeout: 20))
        XCTAssertFalse(result.exists, "Host-only match appeared in downloaded search")
        try await host.post("heal")
        XCTAssertTrue(result.waitForExistence(timeout: 70), "Host-only match was not added to search results")
        XCTAssertTrue(app.staticTexts["All host histories searched"].waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(app.textViews["host-only marker 6e72"].waitForExistence(timeout: 30),
                      "Selecting a host-only result did not load its matching message")
    }

    /// A silently dead link is noticed and shown, then comes back on its own. Idle, nothing but
    /// the ping can tell: up to 40s, then the 5s grace. The notice overlays the list without
    /// moving its content; Settings stays truthful. Short interruptions are covered by the
    /// connection presentation tests, where recovery timing is controlled.
    @MainActor
    func testReconnectingLinkToastClearsAfterSustainedOutage() async throws {
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
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { composer.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Composer did not take focus")
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
        while try await !rig.answerStarted(for: "lost receipt") {
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
        let starts = try await rig.answerStarts(for: "lost receipt")
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

    func answerStarted(for text: String) async throws -> Bool {
        struct Reply: Decodable { var started: Bool }
        return try await get(Reply.self, "answer-started", query: [URLQueryItem(name: "text", value: text)]).started
    }

    func answerStarts(for text: String) async throws -> Int {
        struct Reply: Decodable { var count: Int }
        return try await get(Reply.self, "answer-started", query: [URLQueryItem(name: "text", value: text)]).count
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let url = control.appending(path: path).appending(queryItems: query)
        return try JSONDecoder().decode(type, from: try await URLSession.shared.data(from: url).0)
    }
}
