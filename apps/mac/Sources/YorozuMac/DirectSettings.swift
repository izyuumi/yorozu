import Foundation
import SwiftUI

/// The opt-in direct path to paired phones over Tailscale. Off by default: nothing listens and
/// phones are told nothing. On, the sidecar listens on 127.0.0.1 and `tailscale serve`
/// publishes that port to the tailnet over HTTPS, so there is no firewall prompt and no
/// plain-text websocket. The relay stays for pairing, notifications and fallback.
@MainActor
final class DirectConnection: ObservableObject {
    static let shared = DirectConnection()
    nonisolated static let key = "directConnectionEnabled"
    /// One loopback port, used both for the sidecar and as the tailnet's HTTPS port.
    nonisolated static let port = 8443

    enum Status: Equatable, Sendable {
        case off
        case working
        /// Published and listening; phones get this address sealed.
        case on(url: String)
        /// Tailscale is missing, not running, or refused: the command to run by hand.
        case manual(reason: String, command: String)
    }

    @Published private(set) var status: Status = .off
    /// What the sidecar is started with; nil while the path is off or not published.
    private(set) var sidecarEnvironment: [String: String]?

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    /// Called at launch and whenever the toggle flips. Restarts the sidecar only when what it
    /// should listen on changed.
    func apply(restart: @escaping @MainActor () -> Void) {
        let before = sidecarEnvironment
        let enabled = enabled
        status = .working
        Task {
            let result = await Task.detached { enabled ? Self.publish() : Self.unpublish() }.value
            status = result.status
            sidecarEnvironment = result.environment
            if before != result.environment { restart() }
        }
    }

    nonisolated static var serveCommand: String { "tailscale serve --bg --https=\(port) http://127.0.0.1:\(port)" }
    nonisolated static var unserveCommand: String { "tailscale serve --https=\(port) off" }

    private struct Result: Sendable { var status: Status; var environment: [String: String]? }

    private nonisolated static func publish() -> Result {
        guard let cli = cliPath else {
            return Result(status: .manual(reason: "The tailscale command was not found. Install Tailscale's CLI, then run:",
                command: serveCommand), environment: nil)
        }
        guard let host = selfDNSName(cli) else {
            return Result(status: .manual(reason: "Tailscale is not running or not signed in. Once it is, run:",
                command: serveCommand), environment: nil)
        }
        let (code, output) = run(cli, ["serve", "--bg", "--https=\(port)", "http://127.0.0.1:\(port)"])
        guard code == 0 else {
            let reason = output.localizedCaseInsensitiveContains("https") || output.localizedCaseInsensitiveContains("cert")
                ? "Turn on HTTPS certificates for your tailnet in the Tailscale admin console (DNS → HTTPS Certificates), then run:"
                : "Tailscale refused: \(output.prefix(200)). Run:"
            return Result(status: .manual(reason: reason, command: serveCommand), environment: nil)
        }
        let url = "wss://\(host):\(port)"
        return Result(status: .on(url: url),
            environment: ["YOROZU_DIRECT_PORT": String(port), "YOROZU_DIRECT_URL": url])
    }

    /// Off: drop the rule if the CLI is there; nothing else to do, the sidecar stops listening.
    private nonisolated static func unpublish() -> Result {
        if let cli = cliPath { _ = run(cli, ["serve", "--https=\(port)", "off"]) }
        return Result(status: .off, environment: nil)
    }

    private nonisolated static var cliPath: String? {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
         "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// This Mac's MagicDNS name, `host.tailnet.ts.net`, or nil when Tailscale is not up.
    private nonisolated static func selfDNSName(_ cli: String) -> String? {
        let (code, output) = run(cli, ["status", "--json"])
        guard code == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = (me["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !name.isEmpty
        else { return nil }
        return name
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// The toggle and its one status line, inside the relay section of General.
struct DirectConnectionRow: View {
    @ObservedObject var direct: DirectConnection
    let restart: @MainActor () -> Void
    @AppStorage(DirectConnection.key) private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            Text("Direct connection over Tailscale")
            Text("Paired phones on your tailnet skip the relay. The relay still pairs, notifies, and takes over when direct is unreachable.")
        }
        .onChange(of: enabled) { _, _ in direct.apply(restart: restart) }
        switch direct.status {
        case .off:
            EmptyView()
        case .working:
            LabeledContent("Direct", value: "Setting up…")
        case .on(let url):
            LabeledContent("Direct", value: url).textSelection(.enabled)
        case .manual(let reason, let command):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason).foregroundStyle(.secondary)
                HStack {
                    Text(command).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
                Button("Try Again") { direct.apply(restart: restart) }
            }
        }
    }
}
