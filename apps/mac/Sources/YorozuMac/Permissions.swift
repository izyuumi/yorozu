import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid

/// Every grant the onboarding wizard walks, in the order it walks them. The checks live here
/// as plain functions of system state so a later ticket can unit test them without the UI.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, screenRecording, fullDiskAccess, automation, inputMonitoring, neverSleep
    /// Not a TCC grant: the last step of the same wizard, where the approval floor is set.
    case approvals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .fullDiskAccess: "Full Disk Access"
        case .automation: "Automation"
        case .inputMonitoring: "Input Monitoring"
        case .neverSleep: "Never Sleep"
        case .approvals: "Approvals"
        }
    }

    var detail: String {
        switch self {
        case .accessibility:
            "Lets the agent read the window you are looking at as an accessibility tree, and click or type in it."
        case .screenRecording:
            "Used only when a window exposes no accessibility tree, so the agent can fall back to a screenshot."
        case .fullDiskAccess:
            "Lets the agent read and write files anywhere you can, including Mail and Safari data."
        case .automation:
            "Lets the agent drive Calendar, Mail, Reminders and System Events. Each app asks separately, and may launch while it does."
        case .inputMonitoring:
            "Lets the agent synthesise keystrokes and clicks so it can act on what it sees."
        case .neverSleep:
            "Keeps this Mac awake so the agent can answer your phone while you are away. Reversible here or in the menu at any time."
        case .approvals:
            "The agent asks before acting when it is unsure, and learns from your answers. These two limits it can never learn its way past."
        }
    }

    /// Deep link to the exact System Settings pane, nil when the grant is ours to make.
    var settingsURL: URL? {
        let pane: String? = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .automation: "Privacy_Automation"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .neverSleep, .approvals: nil
        }
        return pane.flatMap { URL(string: "x-apple.systempreferences:com.apple.preference.security?\($0)") }
    }

    @MainActor
    func isGranted() -> Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .fullDiskAccess: Permission.hasFullDiskAccess()
        case .automation: Permission.automationTargets.allSatisfy { Permission.hasAutomation(bundleID: $0.bundleID) }
        case .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .neverSleep: NeverSleep.shared.isRunning
        // Nothing to verify: the floor always has a value, defaulted before it is ever shown.
        case .approvals: true
        }
    }

    /// Asks the system for its own prompt where an API exists; the rest the user flips by hand.
    @MainActor
    func request() {
        switch self {
        case .accessibility:
            // Literal rather than kAXTrustedCheckOptionPrompt: the constant is imported as a
            // mutable global, which Swift 6 refuses to read across isolation.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .automation:
            _ = isGranted()  // the probe itself is what makes macOS ask.
        case .fullDiskAccess, .neverSleep, .approvals:
            break  // No API: only the System Settings pane, or the user, can settle these.
        }
    }

    // MARK: - Full Disk Access

    /// Paths only Full Disk Access unlocks. TCC exposes no API for this grant, so reading one
    /// of these is the probe; a missing file just makes that probe inconclusive.
    static let fullDiskAccessProbes = [
        "Library/Safari/Bookmarks.plist",
        "Library/Application Support/com.apple.TCC/TCC.db",
    ]

    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return fullDiskAccessProbes.contains { path in
            guard let handle = try? FileHandle(forReadingFrom: home.appending(path: path)) else { return false }
            try? handle.close()
            return true
        }
    }

    // MARK: - Automation

    static let automationTargets: [(name: String, bundleID: String)] = [
        ("Calendar", "com.apple.iCal"),
        ("Mail", "com.apple.mail"),
        ("Reminders", "com.apple.reminders"),
        ("System Events", "com.apple.systemevents"),
    ]

    /// `errAEEventNotPermitted`: TCC refused to deliver the Apple event to that app.
    static let automationDeniedCode = -1743

    static func hasAutomation(bundleID: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: "tell application id \"\(bundleID)\" to name")?.executeAndReturnError(&error)
        // Any other failure (app absent, not scriptable) still means TCC let the event through.
        return (error?[NSAppleScript.errorNumber] as? Int) != automationDeniedCode
    }

    // MARK: - Diagnostics

    /// One line per grant on stdout, so a dev build can be verified without a screenshot.
    @MainActor
    static func logAll() {
        for permission in allCases {
            print("CHECK \(permission.rawValue) \(permission.isGranted() ? "granted" : "denied")")
        }
        fflush(stdout)
    }
}

/// Keeps the Mac awake by owning a `caffeinate` child process: no pmset, no sudo, and the
/// assertion dies with the app, so a crash cannot leave the machine permanently awake.
@MainActor
final class NeverSleep: ObservableObject {
    static let shared = NeverSleep()
    static let defaultsKey = "neverSleep"

    @Published private(set) var isRunning = false
    private var process: Process?

    func start() {
        guard process?.isRunning != true else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-dims"]
        guard (try? task.run()) != nil else { return }
        process = task
        isRunning = true
        UserDefaults.standard.set(true, forKey: Self.defaultsKey)
    }

    /// `persist: false` on quit, so stopping the child does not look like the user opting out.
    func stop(persist: Bool = true) {
        process?.terminate()
        process = nil
        isRunning = false
        if persist { UserDefaults.standard.set(false, forKey: Self.defaultsKey) }
    }

    func restoreFromDefaults() {
        if UserDefaults.standard.bool(forKey: Self.defaultsKey) { start() }
    }
}
