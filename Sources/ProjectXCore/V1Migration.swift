import Foundation

/// What a Yorozu 1 install leaves behind when this app replaces it in place (owner, 2026-10-11), handled once on the
/// first live launch: its watchdog LaunchAgent stops and goes, and its memory notes are imported. Its chats, devices and
/// keys stay where they are, in `~/Library/Application Support/Yorozu`; phones and other Macs pair again.
public enum V1Migration {
    public struct Result: Sendable, Equatable {
        /// A v1 install was found (its folder, its watchdog or its role setting).
        public var found: Bool
        public var watchdogRemoved: Bool
        public var importedNotes: Int
        /// v1 ran as a client of another host Mac (`macRole` = client).
        public var wasClient: Bool
    }

    public static let watchdogLabel = "to.yumi.yorozu.watchdog"

    /// Runs once per data root (the marker `v1-migrated`); nil when it already ran.
    public static func run(dataRoot: URL, memory: MemoryStore?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           defaults: UserDefaults = .standard) async -> Result? {
        let fm = FileManager.default, marker = dataRoot.appendingPathComponent("v1-migrated")
        guard !fm.fileExists(atPath: marker.path) else { return nil }
        let support = home.appendingPathComponent("Library/Application Support",isDirectory: true)
        let v1 = support.appendingPathComponent("Yorozu",isDirectory: true)
        let agent = home.appendingPathComponent("Library/LaunchAgents/\(watchdogLabel).plist")
        let role = defaults.string(forKey: "macRole")
        var result = Result(found: fm.fileExists(atPath: v1.path) || fm.fileExists(atPath: agent.path) || role != nil,
                            watchdogRemoved: false,importedNotes: 0,wasClient: role == "client")
        // The watchdog relaunched v1 every minute and was left loaded on purpose while Sparkle installed an update.
        if fm.fileExists(atPath: agent.path) {
            let launchctl = Process()
            launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launchctl.arguments = ["bootout","gui/\(getuid())/\(watchdogLabel)"]
            launchctl.standardOutput = FileHandle.nullDevice; launchctl.standardError = FileHandle.nullDevice
            try? launchctl.run(); launchctl.waitUntilExit()
            result.watchdogRemoved = (try? fm.removeItem(at: agent)) != nil
        }
        try? fm.removeItem(at: support.appendingPathComponent("\(watchdogLabel)-pause"))
        if let memory { result.importedNotes = await importMemory(from: sources(v1: v1,home: home),into: memory) }
        fm.createFile(atPath: marker.path,contents: nil)
        return result
    }

    /// v1's memory: its own folder, and the notes it wrote into a PAIOS vault (`Workspace/Yorozu Memory`), never the
    /// rest of that vault.
    static func sources(v1: URL,home: URL) -> [URL] {
        var dirs = [v1.appendingPathComponent("memory",isDirectory: true)]
        let vaults = (try? JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")))
                      as? [String:Any])?["vaults"] as? [String:[String:Any]] ?? [:]
        let paios = vaults.values.compactMap { $0["path"] as? String }.map { URL(fileURLWithPath: $0).appendingPathComponent("PAIOS") }
            + [home.appendingPathComponent("My vault/PAIOS"),home.appendingPathComponent("Documents/PAIOS")]
        dirs += paios.map { $0.appendingPathComponent("Workspace/Yorozu Memory",isDirectory: true) }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Each v1 fact becomes an assistant-attributed, unverified note: v1 kept no quote of what the user said, so it
    /// cannot be a user fact here. A note the memory refuses (a secret, too long) is skipped.
    static func importMemory(from dirs: [URL],into memory: MemoryStore) async -> Int {
        var count = 0, seen = Set<String>()
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir,includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "md" && !file.lastPathComponent.hasPrefix(".") {
                guard let text = try? String(contentsOf: file,encoding: .utf8) else { continue }
                let (fields,body) = frontmatter(text)
                let fact = body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fact.isEmpty, seen.insert(fact).inserted else { continue }
                let line = fact.split(separator: "\n").first.map(String.init) ?? fact
                let title = line.count > 100 ? String(line.prefix(99)) + "…" : line
                let provenance = "Imported from Yorozu 1" + (fields["kind"].map { " (\($0))" } ?? "") + (fields["created"].map { ", recorded \($0)" } ?? "") + "."
                let meta = MemoryMetadata(title: title,knowledgeType: "generated_analysis",attribution: "assistant",epistemicStatus: "unverified")
                guard let markdown = try? MemoryDocument(metadata: meta,body: fact + "\n\n" + provenance).markdown,
                      (try? await memory.write(path: "knowledge/" + meta.id + ".md",markdown: markdown,expectedSHA256: nil)) != nil else { continue }
                count += 1
            }
        }
        return count
    }

    /// `key: value` lines between leading `---` fences, and the rest.
    static func frontmatter(_ text: String) -> ([String:String],String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:],text) }
        var fields: [String:String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = value }
        }
        return (fields,lines[(end + 1)...].joined(separator: "\n"))
    }
}
