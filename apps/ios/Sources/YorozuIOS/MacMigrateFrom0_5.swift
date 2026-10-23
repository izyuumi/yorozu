#if os(macOS)
import CryptoKit
import Foundation
import os
import UserNotifications

/// The one-time move of a Mac from Yorozu 0.5.0-beta, whose app Sparkle just replaced (docs/upgrade-from-0.5.md). Runs on
/// launch, without a click, until it succeeds once. Every step can run again. 0.5's data folder is only ever read, by the
/// plugin. Deleted with the rest of the 0.5 migration once the owner has checked every family Mac.
@MainActor
enum MacMigrateFrom0_5 {
    private static let doneKey = "migratedFrom0_5"
    private static let importedKey = "importedChatsFrom0_5"
    /// 0.5 thread ids already converted, so a run cut short carries on without injecting any twice.
    private static let importedThreadsKey = "importedThreadsFrom0_5"
    private static let log = Logger(subsystem: "to.yumi.yorozu", category: "migrate-from-0.5")
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let watchdogLabel = "to.yumi.yorozu.watchdog"
    private static var watchdogPlist: URL { home.appending(path: "Library/LaunchAgents/\(watchdogLabel).plist") }

    /// Each window's task calls it; one run at a time.
    private static var running = false

    static func run(model: AppModel) async {
        let defaults = UserDefaults.standard
        guard !model.isDemo, !running, !defaults.bool(forKey: doneKey) || !defaults.bool(forKey: importedKey) else { return }
        running = true
        defer { running = false }
        if !defaults.bool(forKey: doneKey) { await migrate(model: model) }
        // Apart from the rest, so a Mac that migrated before the import existed (the owner's) imports too.
        guard defaults.bool(forKey: doneKey), !model.isDemo, !Task.isCancelled, await importFrom0_5() else { return }
        defaults.set(true, forKey: importedKey)
    }

    private static func migrate(model: AppModel) async {
        let defaults = UserDefaults.standard
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
    private static func reloadPlugin(model: AppModel) async -> Bool {
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
    private static func pairThisMac(model: AppModel) async -> Bool {
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

    // MARK: Chats and memory

    private static var dataDir: URL { home.appending(path: "Library/Application Support/Yorozu") }
    private static let lastMessages = 40
    private static let messageMax = 4000

    /// 0.5's chats become 0.9 conversations: per thread, `sessions.create` with its key, then one `chat.inject` holding
    /// its last 40 messages as plain text, archived as it was. Then its memory notes go into the agent's workspace. True
    /// once everything is in (or there was nothing); false to try again on the next launch.
    private static func importFrom0_5() async -> Bool {
        let index = dataDir.appending(path: "threads.json")
        guard let openclaw = Shell.find("openclaw") else { return !FileManager.default.fileExists(atPath: index.path) }
        let agent = await channelAgent(openclaw)
        guard await importMemory(openclaw, agent: agent) else { return false }
        guard let data = try? Data(contentsOf: index) else { return true }
        guard let threads = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            log.error("0.5 threads.json unreadable: nothing imported")
            return true
        }
        let defaults = UserDefaults.standard
        var done = Set(defaults.stringArray(forKey: importedThreadsKey) ?? [])
        // Oldest activity first, so the most recent 0.5 chat ends up on top of the list.
        let ordered = threads.compactMap { thread -> (id: String, record: [String: Any], log: URL, mtime: Date)? in
            guard let id = thread["id"] as? String, !id.isEmpty, !done.contains(id) else { return nil }
            let log = dataDir.appending(path: "threads/\(id.replacing(#/[^\w.-]/#, with: "_")).jsonl")
            let mtime = (try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (id, thread, log, mtime)
        }.sorted { $0.mtime < $1.mtime }
        for thread in ordered {
            guard !Task.isCancelled else { return false }
            let messages = messages(in: thread.log)
            if !messages.isEmpty {
                guard await importThread(openclaw, agent: agent, id: thread.id, record: thread.record, messages: messages) else {
                    return false
                }
            }
            done.insert(thread.id)
            defaults.set(Array(done), forKey: importedThreadsKey)
        }
        log.notice("imported \(ordered.count) 0.5 chats")
        return true
    }

    private static func importThread(
        _ openclaw: String, agent: String, id: String, record: [String: Any], messages: [(user: Bool, text: String)]
    ) async -> Bool {
        let key = "agent:\(agent):yorozu:direct:owner:thread:\(convId(for: id))"
        let firstLine = messages.first { $0.user }?.text.split(separator: "\n").first.map(String.init)
        let title = ((record["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? firstLine ?? "Yorozu 0.5")
        let create: [String: Any] = ["key": key, "agentId": agent, "displayName": String(title.prefix(60))]
        guard let created = await call(openclaw, "sessions.create", create), let sessionId = created["sessionId"] as? String else {
            return false
        }
        let count = messages.count == 1 ? "1 message" : "\(messages.count) messages"
        let body = messages.map { "\($0.user ? "You" : "Yorozu"): \($0.text)" }.joined(separator: "\n\n")
        let message = "Earlier conversation from Yorozu 0.5 (\(count)):\n\n\(body)"
        guard await call(openclaw, "chat.inject", ["sessionKey": key, "message": message]) != nil else { return false }
        if record["archived"] as? Bool == true {
            _ = await call(openclaw, "sessions.patch", ["key": key, "archived": true, "expectedSessionId": sessionId])
        }
        return true
    }

    /// A thread's last 40 messages, oldest first. Attachments come along as their names.
    private static func messages(in log: URL) -> [(user: Bool, text: String)] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n").compactMap { line -> (user: Bool, text: String)? in
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  event["kind"] as? String == "message", let data = event["data"] as? [String: Any],
                  let role = data["role"] as? String, role == "user" || role == "agent" else { return nil }
            let files = (data["attachments"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.map { "[\($0)]" }
            let text = ([(data["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)] + files)
                .filter { !$0.isEmpty }.joined(separator: " ")
            return text.isEmpty ? nil : (role == "user", String(text.prefix(messageMax)))
        }
        return Array(all.suffix(lastMessages))
    }

    /// 0.9 conversation ids are lowercase UUIDs; 0.5's were the client's UUIDs, except a few such as `home`.
    private static func convId(for id: String) -> String {
        if let uuid = UUID(uuidString: id) { return uuid.uuidString.lowercased() }
        var bytes = Array(SHA256.hash(data: Data("yorozu-0.5:\(id)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0f | 0x50
        bytes[8] = bytes[8] & 0x3f | 0x80
        return NSUUID(uuidBytes: bytes).uuidString.lowercased()
    }

    /// 0.5's memory notes, as unverified notes in the agent's workspace (`memory/yorozu-0.5/`), where OpenClaw's memory
    /// search finds them. A note already there is left alone.
    private static func importMemory(_ openclaw: String, agent: String) async -> Bool {
        let sources = [dataDir.appending(path: "memory"),
                       home.appending(path: "Documents/PAIOS/Workspace/Yorozu Memory"),
                       home.appending(path: "My vault/PAIOS/Workspace/Yorozu Memory")]
        let notes = sources.flatMap { dir in
            (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "md" }
        }
        guard !notes.isEmpty else { return true }
        let agents = await Shell.run(openclaw, ["agents", "list", "--json"])
        guard agents.status == 0,
              let list = json(agents.output, "[", "]") as? [[String: Any]],
              let workspace = list.first(where: { $0["id"] as? String == agent })?["workspace"] as? String else {
            log.error("no workspace for agent \(agent, privacy: .public): memory not imported")
            return false
        }
        let target = URL(fileURLWithPath: workspace).appending(path: "memory/yorozu-0.5")
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for note in notes {
                let destination = target.appending(path: note.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                let text = try String(contentsOf: note, encoding: .utf8)
                try (text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nImported from Yorozu 0.5, unverified.\n")
                    .write(to: destination, atomically: true, encoding: .utf8)
            }
        } catch {
            log.error("memory import failed: \(error, privacy: .public)")
            return false
        }
        return true
    }

    /// `channels.yorozu.agent`, or the plugin's default `main` when it is unset.
    private static func channelAgent(_ openclaw: String) async -> String {
        let result = await Shell.run(openclaw, ["config", "get", "channels.yorozu.agent", "--json"])
        guard result.status == 0,
              let agent = try? JSONSerialization.jsonObject(with: Data(result.output.utf8), options: .fragmentsAllowed) as? String,
              !agent.isEmpty else { return "main" }
        return agent
    }

    /// One Gateway method through the CLI, which holds the admin scope the app lacks; its JSON result, or nil on failure.
    private static func call(_ openclaw: String, _ method: String, _ params: [String: Any]) async -> [String: Any]? {
        guard let encoded = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        let result = await Shell.run(openclaw, ["gateway", "call", method, "--json", "--params", String(decoding: encoded, as: UTF8.self)])
        let response = json(result.output, "{", "}") as? [String: Any]
        guard result.status == 0, let response, response["ok"] as? Bool != false else {
            log.error("\(method, privacy: .public) failed: \(result.output.prefix(300), privacy: .public)")
            return nil
        }
        return response
    }

    /// The JSON in a tool's output, which has stderr mixed in: from the first `open` to the last `close`.
    private static func json(_ output: String, _ open: Character, _ close: Character) -> Any? {
        guard let start = output.firstIndex(of: open), let end = output.lastIndex(of: close), start <= end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8))
    }

    private static func nudgeIPhone() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Yorozu was updated to 0.9")
        content.body = String(localized: "Update Yorozu on your iPhone and iPad, then pair them again with Settings › Add a Device…")
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
