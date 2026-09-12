import Foundation
import ServiceManagement

/// Everything that keeps Yorozu running on a Mac nobody is sitting at: the log the other
/// three can be read in, the login item that starts it, and the LaunchAgent that notices
/// when it is gone and opens it again.
///
/// Why any of this exists: the app was found not running one morning with no crash report,
/// no log line and no login item, and three releases it had never picked up. A remote Mac
/// that answers a phone has to come back by itself from every one of those.

/// The one log the app, its sidecar and the watchdog script all append to.
///
/// A plain file rather than `os_log`: the thing being diagnosed is an app that is *not
/// running*, so the record has to outlive the process and be readable with `tail` over ssh
/// without asking the log store for a process that no longer exists.
public enum Log {
    public static let fileURL = URL.libraryDirectory.appending(path: "Logs/Yorozu/app.log")

    /// The same shape the watchdog script writes, so one `tail` reads as one story.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static func write(_ message: String) {
        let line = Data("\(stamp.string(from: Date())) \(message)\n".utf8)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? line.write(to: fileURL)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

/// The login item, which is the only part of this that survives a restart of the Mac.
///
/// `SMAppService.mainApp` registers the bundle itself — no helper, no plist, and the user can
/// see and revoke it in System Settings › General › Login Items. It needs a real bundle, so
/// `swift run` fails here; that is logged and otherwise ignored.
public enum LoginItem {
    /// Set once, so a user who turns the login item off does not have it turned back on by
    /// the next launch. The same trick ``Updates`` uses for Sparkle's preferences.
    private static let configuredKey = "YorozuLoginItemConfigured"

    public static var status: SMAppService.Status { SMAppService.mainApp.status }
    public static var isEnabled: Bool { status == .enabled }

    /// What to show next to the toggle. `.requiresApproval` is the one worth spelling out:
    /// the app has asked, and the user has to finish it in System Settings.
    public static var statusText: String {
        switch status {
        case .enabled: "Registered with macOS."
        case .requiresApproval: "Waiting for you to allow it in System Settings › General › Login Items."
        case .notFound: "Not available — this build is not an installed app bundle."
        default: "Not registered."
        }
    }

    public static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("login item: \(enabled ? "registered" : "unregistered")")
        } catch {
            Log.write("login item: \(enabled ? "register" : "unregister") failed — \(error.localizedDescription)")
        }
        UserDefaults.standard.set(true, forKey: configuredKey)
    }

    /// On by default, but only the first time: an existing install that predates the login
    /// item gets one, and a user who said no keeps saying no.
    public static func enableByDefaultOnce() {
        guard !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        set(true)
    }
}

/// A user LaunchAgent that runs `watchdog.sh` every minute and opens the app again if it is
/// not there.
///
/// Deliberately outside the app: the failure it exists for is the app being gone, so nothing
/// inside the app can be the thing that notices. `launchd` is already running, already
/// supervises user agents, and needs no daemon of ours to supervise it in turn.
///
/// Every path is derived from the running bundle rather than hardcoded to `/Applications`,
/// which is what lets a test install of the app supervise itself under its own label without
/// going anywhere near the real one.
public enum Watchdog {
    public static let defaultsKey = "watchdogEnabled"

    /// How long a deliberate Quit holds the watchdog off. Long enough that quitting sticks,
    /// short enough that a Mac left quit by accident is back before the day is out.
    public static let pauseDuration: TimeInterval = 600

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "to.yumi.yorozu" }

    public static var label: String { "\(bundleID).watchdog" }
    public static var plistURL: URL {
        URL.libraryDirectory.appending(path: "LaunchAgents/\(label).plist")
    }
    /// Keyed by bundle id, so a test build's pause cannot silence the real app's watchdog.
    public static var pauseURL: URL {
        URL.libraryDirectory.appending(path: "Application Support/\(bundleID).watchdog-pause")
    }
    static var scriptURL: URL? { Bundle.main.url(forResource: "watchdog", withExtension: "sh") }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// On unless turned off, and turning it off is what removes the agent.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            newValue ? install() : remove()
        }
    }

    // MARK: - The agent

    /// Written and re-bootstrapped on every launch, not just the first: an update moves the
    /// bundle, and a plist pointing at yesterday's path supervises nothing.
    public static func install() {
        guard let script = scriptURL else {
            Log.write("watchdog: no watchdog.sh in this bundle, not installed")
            return
        }
        let text = plist(
            label: label,
            script: script.path,
            app: Bundle.main.bundlePath,
            pause: pauseURL.path,
            log: Log.fileURL.path
        )
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            Log.write("watchdog: could not write \(plistURL.path) — \(error.localizedDescription)")
            return
        }
        bootout()
        launchctl(["bootstrap", domain, plistURL.path])
        Log.write("watchdog: installed \(label) for \(Bundle.main.bundlePath)")
    }

    public static func remove() {
        bootout()
        try? FileManager.default.removeItem(at: plistURL)
        Log.write("watchdog: removed \(label)")
    }

    /// The agent, as text. Pure so a test can read it without touching `~/Library`.
    ///
    /// `StartInterval` rather than `KeepAlive`: launchd's own keep-alive would own the app's
    /// process and fight `open`, Dock activation and Sparkle's relaunch. A minute's poll that
    /// only ever calls `open -a` leaves the app an ordinary app.
    static func plist(label: String, script: String, app: String, pause: String, log: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(escaped(label))</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/sh</string>
            <string>\(escaped(script))</string>
            <string>\(escaped(app))</string>
            <string>\(escaped(pause))</string>
            <string>\(escaped(log))</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>StartInterval</key><integer>60</integer>
        </dict>
        </plist>

        """
    }

    /// Paths are user data: a Mac whose owner is called "Ben & Jerry" has an ampersand in
    /// every one of them, and an unescaped one makes the whole agent unparseable.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static var domain: String { "gui/\(getuid())" }

    /// bootout first: bootstrap on an already-loaded label is an error, not an update.
    private static func bootout() { launchctl(["bootout", "\(domain)/\(label)"]) }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - Pausing

    /// Quitting on purpose has to stick. The app writes a deadline here on its way out and
    /// the script honours it; a crash writes nothing, so a crash is relaunched.
    public static func pause(for seconds: TimeInterval = pauseDuration) {
        let deadline = Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        try? FileManager.default.createDirectory(
            at: pauseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(deadline)\n".write(to: pauseURL, atomically: true, encoding: .utf8)
        Log.write("quit: watchdog paused for \(Int(seconds))s")
    }

    /// Cleared on launch, so a Mac that is up again is supervised again — otherwise a crash
    /// in the ten minutes after a relaunch would go unnoticed.
    public static func clearPause() {
        guard FileManager.default.fileExists(atPath: pauseURL.path) else { return }
        try? FileManager.default.removeItem(at: pauseURL)
    }

    /// The script's own rule, in Swift, so it can be tested: paused only by a deadline in the
    /// future. Anything unreadable is not a pause — the safe answer is to supervise.
    static func isPaused(contents: String?, now: Date = Date()) -> Bool {
        guard let deadline = contents.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        else { return false }
        return Double(deadline) > now.timeIntervalSince1970
    }
}
