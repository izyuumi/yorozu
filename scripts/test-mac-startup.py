#!/usr/bin/env python3
"""Execute the shipping launch callback with OS/persistence boundaries replaced.

No app launch, TCC prompt, login item, watchdog, pairing, or user defaults mutation.
The callback name is AppKit's contract; the test does not assert its source text.
"""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / "apps/mac/Sources/YorozuMac/YorozuMacApp.swift").read_text()
start = source.index("    func applicationDidFinishLaunching(")
end = source.index("    func applicationShouldHandleReopen(", start)
callback = source[start:end]
session = (ROOT / "apps/mac/Sources/YorozuMac/MacChatSession.swift").read_text()
session_start = session[session.index("    func start() {"):session.index("    func select(")]
role_selection = session[session.index("    func select("):session.index("    enum PairingError:")]
host_start = session[session.index("    private func startHost() {"):session.index("    private func", session.index("    private func startHost() {") + 1)]

fixture = r'''
import AppKit
import CoreServices
import Foundation

@MainActor enum Effects {
    static var privacyProbes = 0
    static var loginRegistrations = 0
    static var awakeRestores = 0
    static var sessionsStarted = 0
    static var cacheAvailable = true
}
enum MacRole: String, CaseIterable { case host, client }
@MainActor final class MacChatSession {
    static let shared = MacChatSession()
    var role: MacRole?
    var local = Model()
    var model: Model { local }
    var failure: String?
    static let roleKey = "fixture-role"
    var hosts = MultiHostModel()
    var relays: [String: Int] = [:]
    var retiringClients: Task<Void, Never>?
    let store = Store()
    func startClients() { Effects.sessionsStarted += 1 }
    func configure(_ model: Model) {}
    static func idleModel() -> Model { Model() }
    static func localModel() throws -> Model {
        if !Effects.cacheAvailable { throw CocoaError(.fileReadNoPermission) }
        return Model()
    }
SESSION_START
ROLE_SELECTION
HOST_START
}
@MainActor final class Store { var lastUsedHostID: String? }
@MainActor final class MultiHostModel {
    struct Host { let id: String }
    var sessions: [Host] = []
    init(lastUsedHostID: String? = nil) {}
    func suspend() {}
    func remove(_ id: String) async {}
}
@MainActor final class Model {
    func start() {}
    func close() {}
}
@MainActor final class Sidecar {
    static let shared = Sidecar()
    func start() { Effects.sessionsStarted += 1 }
    func stop() {}
}
enum LocalSocketTransport { static func defaultPath() -> String { "/fixture/socket" } }
final class FileManager: Sendable {
    static let `default` = FileManager()
    func removeItem(atPath path: String) throws {}
    func fileExists(atPath path: String) -> Bool { true }
}
@MainActor final class DirectConnection {
    static let shared = DirectConnection()
    static let key = "fixture-direct"
    func apply(_ action: () -> Void) { action() }
}
@MainActor enum Permission {
    static func logAll() async { Effects.privacyProbes += 1 }
}
@MainActor enum TextScale { static func acceptUnshiftedPlus() {} }
enum Log { static func write(_ value: String) {} }
@MainActor enum Watchdog {
    static var isEnabled = true
    static func remove() {}
    static func clearPause() {}
    static func install() {}
}
@MainActor enum LoginItem {
    static func set(_ value: Bool) {}
    static func enableByDefaultOnce() { Effects.loginRegistrations += 1 }
}
@MainActor enum HostWindowMode {
    static var active: Bool { MacChatSession.shared.role == .host }
    static var pendingExplicitOpen = false
    static let updateRelaunchKey = "fixture-update-relaunch"
}
@MainActor enum Updates { static func start() {} }
@MainActor final class NeverSleep {
    static let shared = NeverSleep()
    func restoreFromDefaults() { Effects.awakeRestores += 1 }
}
@MainActor final class LocalNotifications {
    static let shared = LocalNotifications()
    func start() {}
}
@MainActor enum Showcase { static func attach(to model: Model) {} }
// Shadow Foundation's global preferences; every callback read/write stays in memory.
final class UserDefaults: Sendable {
    static let standard = UserDefaults()
    func bool(forKey key: String) -> Bool { false }
    func removeObject(forKey key: String) {}
    func set(_ value: String, forKey key: String) {}
}
@MainActor final class LaunchFixture {
CALLBACK
}
@main struct Check {
    @MainActor static func main() async throws {
        let delegate = LaunchFixture()
        // Exercise the startup boundary for unselected, stored-client, and host roles.
        // Pairing/history migration has its own session fixture.
        let roles: [MacRole?] = [nil, .client, .client, .host, .client, nil, .host]
        for (index, role) in roles.enumerated() {
            MacChatSession.shared.role = role
            // Failed host cache readiness must not start global permission probes.
            Effects.cacheAvailable = index != roles.count - 1
            Effects.privacyProbes = 0
            Effects.loginRegistrations = 0
            Effects.awakeRestores = 0
            Effects.sessionsStarted = 0
            delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("fixture")))
            // Wait for any asynchronously scheduled diagnostic to execute.
            try await Task.sleep(for: .milliseconds(50))
            check(Effects.privacyProbes == 0, "Startup must not probe protected resources: \(String(describing: role))")
            check(Effects.loginRegistrations == (role == .host ? 1 : 0), "Only host launch may auto-register availability")
            check(Effects.awakeRestores == (role == .host ? 1 : 0), "Only host launch may restore keep-awake")
            check(Effects.sessionsStarted == (role == nil ? 0 : 1), "Role session startup must remain intact")
        }
        let session = MacChatSession.shared
        session.role = .client
        Effects.cacheAvailable = true
        Effects.loginRegistrations = 0
        Effects.sessionsStarted = 0
        session.select(.host)
        check(Effects.loginRegistrations == 1 && Effects.sessionsStarted == 1,
              "Choosing Host must register availability and start its sidecar")
        session.select(.host)
        check(Effects.loginRegistrations == 1, "Selecting the same role must remain a no-op")
        session.select(.client)
        try await Task.sleep(for: .milliseconds(50))
        check(session.role == .client && Effects.loginRegistrations == 1 && Effects.sessionsStarted == 2,
              "Switching to Client must resume clients without host registration")
        session.clearRole()
        session.start()
        check(session.role == nil && Effects.sessionsStarted == 2, "Clearing/cancelling the role must not start a host")
        Effects.cacheAvailable = false
        session.select(.host)
        check(session.failure != nil && Effects.privacyProbes == 0,
              "Missing host readiness must report failure without probing privacy grants")
        print("PASS Mac launch/role changes: no privacy probes; host-only availability; repeated launches; cancellation; failed host readiness")
    }
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: " + message); exit(1) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="yorozu-startup-") as directory:
    path = Path(directory)
    swift = path / "Check.swift"
    swift.write_text(fixture.replace("CALLBACK", callback).replace("SESSION_START", session_start)
                     .replace("ROLE_SELECTION", role_selection).replace("HOST_START", host_start))
    executable = path / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(path / "cache"),
                    str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
