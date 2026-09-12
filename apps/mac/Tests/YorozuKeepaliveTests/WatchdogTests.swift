import Foundation
import Testing

@testable import YorozuKeepalive

/// The agent launchd is handed, and the rule that decides whether a Quit sticks.
///
/// Both are tested as text and as behaviour: the plist because a typo in it is a watchdog
/// that silently never runs, and the pause because the two halves of that rule live in two
/// languages — ``Watchdog/isPaused(contents:now:)`` here and the `[ -lt ]` in watchdog.sh —
/// and a Mac only ever obeys the second one.

// MARK: - The agent

@Test func agentNamesTheScriptAndItsThreePaths() throws {
    let text = Watchdog.plist(
        label: "to.yumi.yorozu.watchdog",
        script: "/Applications/Yorozu.app/Contents/Resources/watchdog.sh",
        app: "/Applications/Yorozu.app",
        pause: "/Users/x/Library/Application Support/to.yumi.yorozu.watchdog-pause",
        log: "/Users/x/Library/Logs/Yorozu/app.log"
    )
    #expect(text.contains("<key>Label</key><string>to.yumi.yorozu.watchdog</string>"))
    #expect(text.contains("<string>/bin/sh</string>"))
    #expect(text.contains("<string>/Applications/Yorozu.app/Contents/Resources/watchdog.sh</string>"))
    #expect(text.contains("<string>/Applications/Yorozu.app</string>"))
    #expect(text.contains("<string>/Users/x/Library/Logs/Yorozu/app.log</string>"))
    // The two keys that make it a watchdog rather than a one-shot: at login, then every minute.
    #expect(text.contains("<key>RunAtLoad</key><true/>"))
    #expect(text.contains("<key>StartInterval</key><integer>60</integer>"))
}

/// launchd parses this with a real XML parser, so an unescaped path is a dead watchdog and
/// not a mangled one — nothing loads, and nothing says why.
@Test func agentSurvivesAnAmpersandInThePath() throws {
    let text = Watchdog.plist(
        label: "to.yumi.yorozu.watchdog",
        script: "/Users/ben & jerry/Yorozu.app/Contents/Resources/watchdog.sh",
        app: "/Users/ben & jerry/Yorozu.app",
        pause: "/tmp/pause",
        log: "/tmp/log"
    )
    #expect(text.contains("/Users/ben &amp; jerry/Yorozu.app"))
    #expect(!text.contains("jerry/Yorozu.app</string>\n    <string>/Users/ben & "))
    // The real check: launchd's parser is happy with it.
    let data = try #require(text.data(using: .utf8))
    let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    let arguments = try #require(parsed?["ProgramArguments"] as? [String])
    #expect(arguments.contains("/Users/ben & jerry/Yorozu.app"))
    #expect(parsed?["StartInterval"] as? Int == 60)
}

// MARK: - The pause

@Test func onlyADeadlineInTheFutureIsAPause() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(Watchdog.isPaused(contents: "1000600\n", now: now))
    #expect(!Watchdog.isPaused(contents: "999400\n", now: now))
    // Nothing to read is not a pause: an app that never quit on purpose gets supervised.
    #expect(!Watchdog.isPaused(contents: nil, now: now))
    #expect(!Watchdog.isPaused(contents: "", now: now))
    #expect(!Watchdog.isPaused(contents: "soon", now: now))
}

// MARK: - The script itself

/// The shipped script, run for real against a bundle path that does not exist. It logs
/// before it launches anything, so the log is the record of what it decided — and `open -a`
/// on a missing bundle cannot start an app, so nothing appears on screen either way.
private func runWatchdog(pause: String?) throws -> String {
    let directory = URL.temporaryDirectory.appending(path: "watchdog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let pauseFile = directory.appending(path: "pause")
    if let pause { try pause.write(to: pauseFile, atomically: true, encoding: .utf8) }
    let log = directory.appending(path: "app.log")
    // The bundle the agent would supervise: a name no running process can match.
    let app = directory.appending(path: "Absent-\(UUID().uuidString).app")

    let script = URL(filePath: #filePath)
        .deletingLastPathComponent()  // YorozuKeepaliveTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // apps/mac
        .appending(path: "Resources/watchdog.sh")

    let task = Process()
    task.executableURL = URL(filePath: "/bin/sh")
    task.arguments = [script.path, app.path, pauseFile.path, log.path]
    try task.run()
    task.waitUntilExit()
    #expect(task.terminationStatus == 0)
    return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
}

@Test func scriptRelaunchesAnAppThatIsNotRunning() throws {
    #expect(try runWatchdog(pause: nil).contains("not running, relaunching"))
}

@Test func scriptHoldsOffWhileAQuitIsStillPaused() throws {
    let deadline = Int(Date().addingTimeInterval(600).timeIntervalSince1970)
    #expect(try runWatchdog(pause: "\(deadline)\n").isEmpty)
}

@Test func scriptResumesOnceThePauseHasExpired() throws {
    let deadline = Int(Date().addingTimeInterval(-1).timeIntervalSince1970)
    #expect(try runWatchdog(pause: "\(deadline)\n").contains("not running, relaunching"))
}

/// The case that decides whether a crash is ever noticed: a pause file the app never wrote
/// properly must not read as "leave it down".
@Test func scriptTreatsAnUnreadablePauseAsNoPause() throws {
    #expect(try runWatchdog(pause: "not a number\n").contains("not running, relaunching"))
}
