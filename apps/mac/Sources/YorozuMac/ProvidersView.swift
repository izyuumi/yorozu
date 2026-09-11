import AppKit
import Foundation
import Security
import SwiftUI

/// Settings behind the three provider cards. The OpenAI-compatible key lives in the
/// Keychain; the base URL and the model chain are plain defaults. The sidecar reads all
/// three as environment variables. See docs/spec-v1.html section 2.
enum ProviderSettings {
    static let baseUrlKey = "YOROZU_BASE_URL"
    static let chainKey = "YOROZU_MODEL_CHAIN"

    /// The sidecar's environment: the app's own, plus whatever the cards configured.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        for key in [baseUrlKey, chainKey] {
            if let value = defaults.string(forKey: key), !value.isEmpty { environment[key] = value }
        }
        if let key = Keychain.read(), !key.isEmpty { environment["YOROZU_API_KEY"] = key }
        return environment
    }
}

/// The OpenAI-compatible API key. Kept in the Keychain, never in defaults, and never
/// read back into the UI: the view only asks whether one is stored.
enum Keychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "to.yumi.yorozu",
            kSecAttrAccount as String: "openai-api-key",
        ]
    }

    static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var entry = query
        entry[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(entry as CFDictionary, nil) == errSecSuccess
    }

    static var hasKey: Bool { read()?.isEmpty == false }
}

/// One JSON line from `<runtime> probe`: whether each card is usable, and why not.
struct ProbeReport: Decodable {
    struct Card: Decodable {
        let ok: Bool
        let reason: String?
    }

    let claude: Card
    let codex: Card
    let openai: Card
}

@MainActor
final class ProviderProbe: ObservableObject {
    @Published private(set) var report: ProbeReport?
    @Published private(set) var running = false

    func run() {
        guard !running else { return }
        running = true
        let command = (ProcessInfo.processInfo.environment["YOROZU_RUNTIME_CMD"]
            ?? Sidecar.defaultCommand) + " probe"
        let environment = ProviderSettings.environment()
        Task { [weak self] in
            let data = await Task.detached { Self.capture(command, environment) }.value
            self?.report = data.flatMap { try? JSONDecoder().decode(ProbeReport.self, from: $0) }
            self?.running = false
        }
    }

    nonisolated private static func capture(
        _ command: String,
        _ environment: [String: String]
    ) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
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
    @AppStorage(ProviderSettings.baseUrlKey) private var baseUrl = ""
    @AppStorage(ProviderSettings.chainKey) private var chain = ""
    @State private var apiKey = ""
    @State private var keyStored = Keychain.hasKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Providers").font(.headline)
                Spacer()
                Button(probe.running ? "Checking…" : "Re-check") { probe.run() }
                    .disabled(probe.running)
            }

            card("Claude", probe.report?.claude) {
                Button("Log in") { openLogin("claude auth login") }
            }
            card("Codex", probe.report?.codex) {
                Button("Log in") { openLogin("codex login") }
            }
            card("OpenAI-compatible", probe.report?.openai) {
                TextField("Base URL", text: $baseUrl)
                SecureField("API key", text: $apiKey)
                    .onSubmit {
                        keyStored = Keychain.write(apiKey) && !apiKey.isEmpty
                        apiKey = ""
                        probe.run()
                    }
                Text(keyStored ? "Key stored in Keychain." : "No key stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model chain").font(.subheadline)
                TextField("claude-cli/claude-sonnet-5,openai/gpt-4o-mini", text: $chain)
                Text("First that answers wins. Restart to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { probe.run() }
    }

    /// A card is green only when the runtime could actually use it.
    @ViewBuilder
    private func card(
        _ name: String,
        _ state: ProbeReport.Card?,
        @ViewBuilder controls: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: state?.ok == true ? "circle.fill" : "circle")
                    .foregroundStyle(state?.ok == true ? .green : .red)
                    .accessibilityLabel(state?.ok == true ? "\(name) ready" : "\(name) unavailable")
                Text(name)
                Spacer()
            }
            if let reason = state?.reason, state?.ok != true {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            controls()
        }
    }
}
