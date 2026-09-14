import AppKit
import Foundation
import Security
import SwiftUI

/// The providers the runtime may use, as a list the user owns: `providers.json` in the state
/// directory, in chain order. Keys never go in that file — each entry names a `keyRef`, the key
/// itself lives in the Keychain, and the sidecar is handed it as an environment variable.
/// See docs/spec-v1.html section 2.
struct ProviderEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case claudeCli = "claude-cli"
        case codexCli = "codex-cli"
        case openaiCompat = "openai-compat"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeCli: "Claude (CLI login)"
            case .codexCli: "Codex (CLI login)"
            case .openaiCompat: "OpenAI-compatible endpoint"
            }
        }

        /// The interactive login, for the kinds that have one.
        var loginCommand: String? {
            switch self {
            case .claudeCli: "claude auth login"
            case .codexCli: "codex login"
            case .openaiCompat: nil
            }
        }

        /// Kept in step with `DEFAULT_MODELS` in packages/runtime/src/providers.ts: the CLIs
        /// publish no list to fetch, so these are a starting point the user edits.
        var defaultModels: [String] {
            switch self {
            case .claudeCli: ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
            case .codexCli: ["gpt-5.6-codex", "gpt-5.6"]
            case .openaiCompat: []
            }
        }
    }

    var id: String
    var kind: Kind
    var label: String
    /// `openai-compat` only.
    var baseUrl: String?
    /// Keychain account holding this entry's key. Never the key.
    var keyRef: String?
    var models: [String]
    var enabled: Bool

    /// `<id>/<model>` for each model, which is what the chain and every `model:` resolve against.
    var specs: [String] { models.map { "\(id)/\($0)" } }
}

enum ProvidersStore {
    /// Kept in step with `stateDir()` in packages/runtime/src/memory.ts.
    static var stateDir: URL {
        ProcessInfo.processInfo.environment["YOROZU_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL.applicationSupportDirectory.appending(path: "Yorozu")
    }

    static var file: URL { stateDir.appending(path: "providers.json") }

    static func load() -> [ProviderEntry] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([ProviderEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func save(_ entries: [ProviderEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? data.write(to: file)
    }

    /// A new entry's id: the kind, made unique, and never containing the `/` a spec splits on.
    static func freshId(_ kind: ProviderEntry.Kind, taken: [ProviderEntry]) -> String {
        let base = switch kind {
        case .claudeCli: "claude"
        case .codexCli: "codex"
        case .openaiCompat: "endpoint"
        }
        var id = base
        var n = 2
        while taken.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }
}

/// Settings the sidecar reads from its environment: the relay, the browser, the chain override
/// and every provider key out of the Keychain.
enum ProviderSettings {
    static let baseUrlKey = "YOROZU_BASE_URL"
    static let chainKey = "YOROZU_MODEL_CHAIN"

    /// Mirrors `keyEnvVar` in packages/runtime/src/providers.ts.
    static func keyEnvVar(_ keyRef: String) -> String {
        "YOROZU_KEY_"
            + keyRef.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    }

    /// The sidecar's environment: the app's own, plus whatever Settings configured.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        for key in [baseUrlKey, chainKey, BrowserSettings.key] {
            if let value = defaults.string(forKey: key), !value.isEmpty { environment[key] = value }
        }
        // Unlike the others, the relay has a default worth sending even when nothing is stored.
        environment[RelaySettings.key] = RelaySettings.url
        // One variable per provider entry that has a key, plus the single-key setup the
        // earlier tickets used, which the runtime still falls back to.
        for entry in ProvidersStore.load() {
            guard let ref = entry.keyRef, let key = Keychain.read(ref), !key.isEmpty else { continue }
            environment[keyEnvVar(ref)] = key
        }
        if let key = Keychain.read(), !key.isEmpty { environment["YOROZU_API_KEY"] = key }
        return environment
    }
}

/// API keys. Kept in the Keychain, never in defaults, and never read back into the UI: the
/// views only ask whether one is stored.
enum Keychain {
    static let legacyAccount = "openai-api-key"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "to.yumi.yorozu",
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String = legacyAccount) -> String? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String = legacyAccount) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return true }
        var entry = query(account)
        entry[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(entry as CFDictionary, nil) == errSecSuccess
    }

    static func hasKey(_ account: String = legacyAccount) -> Bool { read(account)?.isEmpty == false }
}

/// One subcommand of the runtime sidecar — `probe`, `models`, `assign`, `assign-cron` — run to
/// completion with the settings' environment. The same binary the app spawns for the relay;
/// the settings talk to it by argument rather than over the relay.
enum RuntimeCommand {
    /// The runtime bundled by `scripts/build-mac.sh` when there is one, else the dev
    /// default: `swift run` from `apps/mac` leaves the repo layout reachable. Quoted
    /// because the command is run through `/bin/sh` and an .app can sit in a path with
    /// spaces. Override either with YOROZU_RUNTIME_CMD.
    static let defaultCommand: String = {
        guard let resources = Bundle.main.resourceURL else {
            return "node ../../packages/runtime/dist/serve.js"
        }
        let node = resources.appendingPathComponent("node").path
        let serve = resources.appendingPathComponent("runtime/dist/serve.js").path
        guard FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.isReadableFile(atPath: serve)
        else { return "node ../../packages/runtime/dist/serve.js" }
        return "'\(node)' '\(serve)'"
    }()

    static func output(_ arguments: String) -> Data? {
        let command = (ProcessInfo.processInfo.environment["YOROZU_RUNTIME_CMD"]
            ?? defaultCommand) + " " + arguments
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProviderSettings.environment()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

/// One JSON line from `<runtime> probe`: whether each configured provider is usable, and why
/// not. Mirrors `ProbeReport` in packages/runtime/src/probe.ts.
struct ProbeReport: Decodable {
    struct Card: Decodable {
        let ok: Bool
        let reason: String?
    }

    let providers: [ProviderEntry]
    let status: [String: Card]
}

@MainActor
final class ProviderProbe: ObservableObject {
    @Published private(set) var report: ProbeReport?
    @Published private(set) var running = false

    func run() {
        guard !running else { return }
        running = true
        Task { [weak self] in
            let data = await Task.detached { RuntimeCommand.output("probe") }.value
            self?.report = data.flatMap { try? JSONDecoder().decode(ProbeReport.self, from: $0) }
            self?.running = false
        }
    }
}

/// Both CLI logins are interactive browser round trips, so they cannot run inside the
/// app: hand the command to Terminal.app and let the user finish it there.
private func openLogin(_ command: String) {
    let script = """
    tell application "Terminal"
        activate
        do script "\(command)"
    end tell
    """
    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
}

struct ProvidersView: View {
    @StateObject private var probe = ProviderProbe()
    @ObservedObject private var sidecar = Sidecar.shared
    /// Loaded once and written back on every edit: this file is the runtime's own configuration.
    @State private var entries: [ProviderEntry] = ProvidersStore.load()

    /// Every model of every enabled entry, in chain order. The first is the default model.
    private var specs: [String] { entries.filter(\.enabled).flatMap(\.specs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Providers").font(.headline)
                Spacer()
                Button(probe.running ? "Checking…" : "Re-check") { probe.run() }
                    .disabled(probe.running)
            }
            Text("Tried top to bottom: the first that answers wins. Drag to reorder.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($entries) { $entry in
                    ProviderRowView(entry: $entry, state: probe.report?.status[entry.id]) {
                        entries.removeAll { $0.id == entry.id }
                    }
                }
                .onMove { from, to in entries.move(fromOffsets: from, toOffset: to) }
            }
            .frame(minHeight: 200)

            HStack {
                Menu("Add Provider") {
                    ForEach(ProviderEntry.Kind.allCases) { kind in
                        Button(kind.title) { add(kind) }
                    }
                }
                .fixedSize()
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default model").font(.subheadline)
                Picker("Default model", selection: Binding(
                    get: { specs.first ?? "" },
                    set: { makeDefault($0) }
                )) {
                    if specs.isEmpty { Text("No models configured").tag("") }
                    ForEach(specs, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .disabled(specs.isEmpty)
                Text("Moves that provider and model to the front of the chain. Restart to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { probe.run() }
        // The probe seeds `providers.json` on a runtime that had none: pick that up.
        .onChange(of: probe.report?.providers) { _, probed in
            if entries.isEmpty, let probed, !probed.isEmpty { entries = probed }
        }
        .onChange(of: entries) { ProvidersStore.save(entries) }
    }

    private func add(_ kind: ProviderEntry.Kind) {
        let id = ProvidersStore.freshId(kind, taken: entries)
        entries.append(
            ProviderEntry(
                id: id,
                kind: kind,
                label: kind == .openaiCompat ? "New endpoint" : id.capitalized,
                baseUrl: kind == .openaiCompat ? "https://api.openai.com/v1" : nil,
                keyRef: kind == .openaiCompat ? id : nil,
                models: kind.defaultModels,
                enabled: true
            )
        )
    }

    /// The default model is just the head of the chain, so choosing one is a reorder.
    private func makeDefault(_ spec: String) {
        guard let slash = spec.firstIndex(of: "/") else { return }
        let id = String(spec[spec.startIndex..<slash])
        let model = String(spec[spec.index(after: slash)...])
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.models.removeAll { $0 == model }
        entry.models.insert(model, at: 0)
        entries.insert(entry, at: 0)
    }
}

/// One provider: its state, its models, and whatever it takes to sign in to it.
private struct ProviderRowView: View {
    @Binding var entry: ProviderEntry
    var state: ProbeReport.Card?
    var onRemove: () -> Void

    @State private var apiKey = ""
    @State private var fetching = false

    private var models: Binding<String> {
        Binding(
            get: { entry.models.joined(separator: ", ") },
            set: {
                entry.models = $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let reason = state?.reason, state?.ok != true {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                TextField("Name", text: $entry.label)
                if entry.kind == .openaiCompat {
                    TextField("Base URL", text: Binding(
                        get: { entry.baseUrl ?? "" },
                        set: { entry.baseUrl = $0 }
                    ))
                    SecureField("API key", text: $apiKey)
                        .onSubmit {
                            let ref = entry.keyRef ?? entry.id
                            entry.keyRef = ref
                            Keychain.write(apiKey, account: ref)
                            apiKey = ""
                        }
                    Text(Keychain.hasKey(entry.keyRef ?? entry.id)
                        ? "Key stored in Keychain."
                        : "No key stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Models, in order", text: models)
                    if entry.kind == .openaiCompat {
                        Button(fetching ? "Fetching…" : "Fetch") { fetchModels() }
                            .disabled(fetching)
                    }
                }
                HStack {
                    if let command = entry.kind.loginCommand {
                        Button("Log in") { openLogin(command) }
                    }
                    Spacer()
                    Button("Remove", role: .destructive, action: onRemove)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state?.ok == true ? "circle.fill" : "circle")
                    .foregroundStyle(state?.ok == true ? .green : .red)
                    .accessibilityLabel(state?.ok == true ? "\(entry.label) ready" : "\(entry.label) unavailable")
                Toggle(entry.label, isOn: $entry.enabled)
                    .toggleStyle(.checkbox)
                Spacer()
                Text(entry.id).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The endpoint's own `/models`, which only the runtime can reach: it holds the key.
    private func fetchModels() {
        // The runtime reads the entry from disk, so the edits have to be there first.
        ProvidersStore.save(ProvidersStore.load().map { $0.id == entry.id ? entry : $0 })
        fetching = true
        let id = entry.id
        Task {
            let data = await Task.detached { RuntimeCommand.output("models \(id)") }.value
            let fetched = String(data: data ?? Data(), encoding: .utf8)?
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            if !fetched.isEmpty { entry.models = fetched }
            fetching = false
        }
    }
}
