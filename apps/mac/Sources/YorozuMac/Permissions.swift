import AppKit
import Foundation

/// The grants themselves live in the `YorozuPermissions` library, shared with the
/// `yorozu-native` helper so that the app, the wizard and the agent all agree on what
/// "granted" means. What is left here is the one switch on this screen that macOS has no
/// say over.

/// Keeps the Mac awake by owning a `caffeinate` child process: no pmset, no sudo, and the
/// assertion dies with the app, so a crash cannot leave the machine permanently awake.
@MainActor
final class NeverSleep: ObservableObject {
    static let shared = NeverSleep()
    /// The same key `Permission.neverSleep` reads its status from.
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
