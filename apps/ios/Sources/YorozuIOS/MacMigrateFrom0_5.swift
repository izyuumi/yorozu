#if os(macOS)
import Foundation
import os
import UserNotifications

/// The one-time move of a Mac from Yorozu 0.5.0-beta, whose app Sparkle just replaced (docs/upgrade-from-0.5.md). Runs on
/// launch, without a click, until it succeeds once. Every step can run again. 0.5's data folder is only ever read, by the
/// plugin. Deleted with the rest of the 0.5 migration once the owner has checked every family Mac.
@MainActor
enum MacMigrateFrom0_5 {
    private static let doneKey = "migratedFrom0_5"
    private static let log = Logger(subsystem: "to.yumi.yorozu", category: "migrate-from-0.5")
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let watchdogLabel = "to.yumi.yorozu.watchdog"
    private static var watchdogPlist: URL { home.appending(path: "Library/LaunchAgents/\(watchdogLabel).plist") }

    /// Each window's task calls it; one run at a time.
    private static var running = false

    static func run(model: V3Model) async {
        let defaults = UserDefaults.standard
        guard !model.isDemo, !running, !defaults.bool(forKey: doneKey) else { return }
        running = true
        defer { running = false }
        guard installedFrom0_5 else { defaults.set(true, forKey: doneKey); return }
        log.notice("0.5 install found: migrating")
        removeWatchdog()
        guard await reloadPlugin(model: model), !model.isDemo, !Task.isCancelled else { return }
        if model.pairing == nil, !(await pairThisMac(model: model)) { return }
        guard !model.isDemo, !Task.isCancelled else { return }
        defaults.set(true, forKey: doneKey)
        nudgeIPhone()
        log.notice("migration from 0.5 done")
    }

    /// 0.5 left its watchdog LaunchAgent, its user defaults (this app shares its bundle id) or its data folder.
    private static var installedFrom0_5: Bool {
        let support = home.appending(path: "Library/Application Support")
        return FileManager.default.fileExists(atPath: watchdogPlist.path)
            || UserDefaults.standard.object(forKey: "onboardingCompleted") != nil
            || FileManager.default.fileExists(atPath: support.appending(path: "Yorozu/threads").path)
    }

    /// 0.5's watchdog relaunched 0.5 every minute and stays loaded through a Sparkle install.
    private static func removeWatchdog() {
        _ = try? Shell.runSync("/bin/launchctl", ["bootout", "gui/\(getuid())/\(watchdogLabel)"])
        try? FileManager.default.removeItem(at: watchdogPlist)
    }

    /// The Gateway keeps running 0.5's plugin from memory until a reload. 0.9's channel schema rejects `socketPath`, which
    /// would stop the next Gateway start, so it goes first. The CLI has the admin scope the app lacks.
    private static func reloadPlugin(model: V3Model) async -> Bool {
        guard !model.isDemo, !Task.isCancelled else { return false }
        guard let openclaw = Shell.find("openclaw") else {
            log.error("openclaw not found: the Gateway keeps 0.5's plugin until it restarts")
            return false
        }
        // Fails when the key is not set, which is the usual case.
        _ = await Shell.run(openclaw, ["config", "unset", "channels.yorozu.socketPath"])
        guard !model.isDemo, !Task.isCancelled else { return false }
        let reload = await Shell.run(openclaw, ["plugins", "reload", "yorozu", "--accept-capabilities", "--json"])
        guard !model.isDemo, !Task.isCancelled else { return false }
        if reload.status == 0, reload.output.range(of: #""restartRequired"\s*:\s*true"#, options: .regularExpression) == nil {
            return true
        }
        log.notice("plugin reload: \(reload.status) \(reload.output, privacy: .public); restarting the Gateway")
        let restart = await Shell.run(openclaw, ["gateway", "restart", "--safe"])
        if restart.status != 0 { log.error("gateway restart failed: \(restart.output, privacy: .public)") }
        return restart.status == 0
    }

    /// This Mac was 0.5's host and never a client: pair it with the plugin on the same machine. The plugin needs a moment
    /// after the reload. The fingerprint check is skipped: the code comes straight from this Mac's own Gateway.
    private static func pairThisMac(model: V3Model) async -> Bool {
        guard let openclaw = Shell.find("openclaw") else { return false }
        for _ in 0..<10 {
            guard !model.isDemo, !Task.isCancelled else { return false }
            let pair = await Shell.run(openclaw, ["yorozu", "pair"])
            guard !model.isDemo, !Task.isCancelled else { return false }
            if pair.status == 0, let range = pair.output.range(of: #"yorozu://pair\S+"#, options: .regularExpression),
               model.submit(String(pair.output[range])) == nil, let payload = model.pendingPairing {
                model.confirm(payload)
                return model.pairing != nil
            }
            try? await Task.sleep(for: .seconds(6))
        }
        log.error("couldn't pair this Mac with its own Gateway")
        return false
    }

    private static func nudgeIPhone() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Yorozu was updated to 0.9")
        content.body = String(localized: "Update Yorozu on your iPhone and iPad too. Your conversations came along.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "migrated-from-0.5", content: content, trigger: nil))
    }
}

/// Runs command-line tools for the migration. A Mac app starts with a bare PATH, so `openclaw` (a Node script) and `node`
/// are looked up where installers put them.
enum Shell {
    struct Result { let status: Int32; let output: String }

    private static let dirs = ["/opt/homebrew/bin", "/usr/local/bin",
                               FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
                               "/usr/bin", "/bin"]
    private static var path: String {
        (dirs + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])).joined(separator: ":")
    }

    static func find(_ tool: String) -> String? {
        path.split(separator: ":").map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ tool: String, _ arguments: [String]) async -> Result {
        await Task.detached { (try? runSync(tool, arguments)) ?? Result(status: -1, output: "couldn't start \(tool)") }.value
    }

    static func runSync(_ tool: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
#endif
