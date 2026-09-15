/// Every macOS privacy grant Yorozu needs, one case each: what it is for, how to read its
/// current state, and how to make macOS show its own prompt for it.
///
/// Shared by the app — the onboarding wizard and the Permissions tab — and by the
/// `yorozu-native` helper, which exposes `permission.status` and `permission.request` so the
/// runtime's `request_permission` tool can ask for a grant mid-conversation. One definition,
/// so "granted" cannot mean two different things in the two processes.
///
/// The reason this is shared at all: TCC reads the **calling binary's** Info.plist for the
/// `NS…UsageDescription` matching the grant, and denies outright — no prompt, an immediate
/// `false` — when it is missing. `yorozu-native` is a bare Mach-O with no bundle, so it
/// carries its own plist in a `__TEXT,__info_plist` section. See scripts/build-mac.sh.

import AVFoundation
import AppKit
import ApplicationServices
import Contacts
import CoreGraphics
import CoreLocation
import EventKit
import IOKit.hid
import MusicKit
import Photos
import ServiceManagement

public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case accessibility, screenRecording, inputMonitoring, fullDiskAccess
    case calendars, reminders, contacts, photos, music, location, camera, microphone
    case files, automation
    /// Not TCC grants: the last two steps of the same wizard, where the Mac is told to
    /// start Yorozu at login and stay awake. They live here so
    /// the wizard and the Permissions tab can walk one list.
    case startAtLogin, neverSleep

    /// The steps macOS has no say over: Yorozu's own settings, asked for in the same wizard
    /// because to the user they are the same list of things to turn on.
    public var isAppSetting: Bool {
        switch self {
        case .startAtLogin, .neverSleep: true
        default: false
        }
    }

    public var id: String { rawValue }

    /// The grants `yorozu-native` can report on and ask for. The app's own settings are not
    /// among them, so the helper has nothing to say about those.
    public static let requestable = allCases.filter { !$0.isAppSetting }

    public var title: String {
        switch self {
        case .accessibility: String(localized: "Accessibility")
        case .screenRecording: String(localized: "Screen Recording")
        case .inputMonitoring: String(localized: "Input Monitoring")
        case .fullDiskAccess: String(localized: "Full Disk Access")
        case .calendars: String(localized: "Calendars")
        case .reminders: String(localized: "Reminders")
        case .contacts: String(localized: "Contacts")
        case .photos: String(localized: "Photos")
        case .music: String(localized: "Music")
        case .location: String(localized: "Location")
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        case .files: String(localized: "Files & Folders")
        case .automation: String(localized: "Automation")
        case .startAtLogin: String(localized: "Start at Login")
        case .neverSleep: String(localized: "Never Sleep")
        }
    }

    public var detail: String {
        switch self {
        case .accessibility:
            String(localized: "Lets the agent read the window you are looking at as an accessibility tree, and click or type in it.")
        case .screenRecording:
            String(localized: "Used only when a window exposes no accessibility tree, so the agent can fall back to a screenshot.")
        case .inputMonitoring:
            String(localized: "Lets the agent synthesise keystrokes and clicks so it can act on what it sees.")
        case .fullDiskAccess:
            String(localized: "Lets the agent read and write files anywhere you can, including Mail and Safari data.")
        case .calendars:
            String(localized: "Lets the agent read your calendar and make, move and cancel events when you ask.")
        case .reminders:
            String(localized: "Lets the agent read your reminder lists and add to or tick off items.")
        case .contacts:
            String(localized: "Lets the agent look up the people you write to, so you can say a name instead of an address.")
        case .photos:
            String(localized: "Lets the agent find and attach pictures from your library.")
        case .music:
            String(localized: "Lets the agent see your music library so it can play what you ask for.")
        case .location:
            String(localized: "Lets the agent answer questions about where you are — travel time, the weather, what is nearby.")
        case .camera:
            String(localized: "Lets the agent take a picture when you ask it to. Never used without you asking.")
        case .microphone:
            String(localized: "Lets the agent listen when you ask it to. Never used without you asking.")
        case .files:
            String(localized: "Your Desktop, Documents, Downloads and cloud drives. macOS asks once per folder.")
        case .automation:
            String(localized: "Lets the agent drive Finder, Safari, Mail, Calendar, Messages and the rest. Each app asks separately and may launch while it does; anything that was not already open is quit again.")
        case .startAtLogin:
            String(localized: "Starts Yorozu whenever you log in, so a Mac that restarted overnight is answering your phone again before you notice it rebooted.")
        case .neverSleep:
            String(localized: "Keeps this Mac awake so the agent can answer your phone while you are away. Reversible here or in the menu at any time.")
        }
    }

    /// Deep link to the exact System Settings pane, for the fallback button. Never what the
    /// agent tells the user to do — it asks for the grant instead. See agents/main.md.
    public var settingsURL: URL? {
        let pane: String? = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        case .photos: "Privacy_Photos"
        case .music: "Privacy_Media"
        case .location: "Privacy_LocationServices"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .files: "Privacy_FilesAndFolders"
        case .automation: "Privacy_Automation"
        case .startAtLogin, .neverSleep: nil
        }
        return pane.flatMap { URL(string: "x-apple.systempreferences:com.apple.preference.security?\($0)") }
    }

    /// Full Disk Access is the one grant macOS exposes no API to ask for: only the user, in
    /// that pane, can turn it on. Everything else prompts.
    public var canPrompt: Bool {
        switch self {
        case .fullDiskAccess, .startAtLogin, .neverSleep: false
        default: true
        }
    }

    // MARK: - Status

    public func isGranted() async -> Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .fullDiskAccess: Permission.hasFullDiskAccess()
        case .calendars: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .contacts: CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .photos: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        case .music: MusicAuthorization.currentStatus == .authorized
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .location: Permission.locationGranted()
        case .files: Permission.hasFileAccess()
        case .automation: Permission.automationGrants().count == Permission.automationTargets.count
        // Read from macOS rather than from a preference of ours: the user can revoke a login
        // item in System Settings, and then ours would be the only copy that still said yes.
        case .startAtLogin: SMAppService.mainApp.status == .enabled
        case .neverSleep: UserDefaults.standard.bool(forKey: "neverSleep")
        }
    }

    // MARK: - Request

    /// Makes macOS show its own prompt, and answers with the state afterwards. Every call is
    /// the real API, never a deep link: the whole point is that the user clicks Allow once
    /// and is never sent to System Settings.
    ///
    /// `.fullDiskAccess` has no API, so it only opens its pane — the caller polls for the
    /// result the way it does for every other grant.
    @discardableResult
    public func request() async -> Bool {
        switch self {
        case .accessibility:
            // A literal rather than kAXTrustedCheckOptionPrompt: the constant is imported as
            // a mutable global, which Swift 6 refuses to read across isolation.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .calendars:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .photos:
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .music:
            _ = await MusicAuthorization.request()
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .location:
            // CoreLocation answers a delegate rather than the caller; the status poll below
            // is what actually reports the user's decision.
            Permission.locationManager.requestWhenInUseAuthorization()
        case .files:
            await Permission.probeFiles()
        case .automation:
            await Permission.probeAutomation()
        case .fullDiskAccess:
            if let settingsURL { NSWorkspace.shared.open(settingsURL) }
        case .startAtLogin, .neverSleep:
            break  // The app's own settings, not the OS's.
        }
        return await isGranted()
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

    // MARK: - Location

    /// Held for the process: `requestWhenInUseAuthorization` is a no-op on a manager that has
    /// already been deallocated, and the prompt would never appear.
    nonisolated(unsafe) static let locationManager = CLLocationManager()

    static func locationGranted() -> Bool {
        [.authorizedAlways, .authorized].contains(locationManager.authorizationStatus)
    }

    // MARK: - Files & folders

    /// The folders macOS gates individually. Listing one is both the probe and the prompt:
    /// `contentsOfDirectory` is what makes TCC ask, and it blocks until the user answers.
    ///
    /// Cloud drives are discovered rather than listed by name — Proton Drive, Dropbox, Google
    /// Drive and the rest all mount as children of `Library/CloudStorage`, and enumerating
    /// that directory itself needs no grant.
    public static func fileProbes() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = ["Desktop", "Documents", "Downloads"].map { home.appending(path: $0) }
        paths.append(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs"))
        let cloud = home.appending(path: "Library/CloudStorage")
        paths += (try? FileManager.default.contentsOfDirectory(
            at: cloud,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A folder that is not there cannot be denied, so it does not count against the grant.
    /// An empty folder lists as `[]` — success — which is the difference from a refusal.
    static func canList(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    static func hasFileAccess() -> Bool { fileProbes().allSatisfy(canList) }

    /// Off the main actor: each folder that has not been decided yet blocks on its own prompt.
    static func probeFiles() async {
        let probes = fileProbes()
        await Task.detached { for url in probes { _ = canList(url) } }.value
    }

    // MARK: - Automation

    /// The apps the agent drives by Apple event. Each one is a separate TCC decision, so each
    /// one has to be asked for separately.
    public static let automationTargets: [(name: String, bundleID: String)] = [
        ("Finder", "com.apple.finder"),
        ("System Events", "com.apple.systemevents"),
        ("Safari", "com.apple.Safari"),
        ("Mail", "com.apple.mail"),
        ("Calendar", "com.apple.iCal"),
        ("Reminders", "com.apple.reminders"),
        ("Notes", "com.apple.Notes"),
        ("Messages", "com.apple.MobileSMS"),
        ("Music", "com.apple.Music"),
        ("Contacts", "com.apple.AddressBook"),
    ]

    /// `errAEEventNotPermitted`: TCC refused to deliver the Apple event to that app.
    public static let automationDeniedCode = -1743

    static let automationDefaultsKey = "automationGrants"

    /// Which targets have said yes. Remembered across launches because the probe is not free:
    /// it sends a real Apple event, which launches the app if it is not running.
    public static func automationGrants() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: automationDefaultsKey) ?? [])
    }

    /// Sends one trivial Apple event per target. The event itself is the prompt, and it does
    /// not return until the user has answered, so the result *is* their decision — there is
    /// nothing to poll for afterwards.
    ///
    /// Apps that were not already running are launched by the event and quit again, so the
    /// wizard does not leave ten windows open behind it. Detached because each launch costs
    /// seconds and the wizard has to keep drawing.
    @discardableResult
    public static func probeAutomation() async -> Set<String> {
        let granted = await Task.detached { () -> Set<String> in
            var granted: Set<String> = []
            for target in automationTargets where probe(bundleID: target.bundleID) {
                granted.insert(target.bundleID)
            }
            return granted
        }.value
        UserDefaults.standard.set(Array(granted), forKey: automationDefaultsKey)
        return granted
    }

    /// One target. Anything other than `-1743` — the app is not installed, or does not answer
    /// `name` — still means TCC let the event through, which is the only thing being asked.
    static func probe(bundleID: String) -> Bool {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        var error: NSDictionary?
        NSAppleScript(source: "tell application id \"\(bundleID)\" to name")?
            .executeAndReturnError(&error)
        if !running {
            // Only what this probe started, and only politely: a terminate() on Finder would
            // just be relaunched by the system anyway.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.terminate()
            }
        }
        return (error?[NSAppleScript.errorNumber] as? Int) != automationDeniedCode
    }

    // MARK: - Diagnostics

    /// One line per grant on stdout, so a dev build can be verified without a screenshot.
    public static func logAll() async {
        for permission in allCases {
            print("CHECK \(permission.rawValue) \(await permission.isGranted() ? "granted" : "denied")")
        }
        fflush(stdout)
    }
}
