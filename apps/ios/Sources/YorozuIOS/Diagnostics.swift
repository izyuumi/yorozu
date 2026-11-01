import OSLog
import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// A plain-text report for whoever debugs Yorozu: app, device, connection state and this run's log.
/// It holds no keys, tokens or message text.
@MainActor
enum Diagnostics {
    nonisolated static let subsystem = "to.yumi.yorozu"

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static func copy(_ model: AppModel) async {
        let text = await report(model)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func report(_ model: AppModel) async -> String {
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let host = model.hostInfo
        var lines = [
            "Yorozu diagnostics \(Date.now.ISO8601Format())",
            "App: \(version) \(Bundle.main.bundleIdentifier ?? "")",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Hardware: \(hardware)",
            "Locale: \(Locale.current.identifier)",
            "Demo: \(model.isDemo)",
            "Paired: \(model.paired)",
            "State: \(model.state)",
            "Outage: \(model.outage.map { "\($0)" } ?? "none")",
            "Relay: \(model.pairing.flatMap { URL(string: $0.pairing.relayUrl)?.host() } ?? "none")",
            "Host: \(host?.app ?? "?") OpenClaw \(host?.hostVersion ?? "?") protocol \(host.map { "\($0.protocolMin)-\($0.protocolMax)" } ?? "?")",
            "Host capabilities: \(host?.capabilities.joined(separator: ",") ?? "")",
            "Conversations: \(model.conversations.count), stalled \(model.stalled.count)",
            "Devices: \(model.devices?.count.description ?? "unknown")",
            "Notifications: \(notificationName(notifications))",
            "Voice engine: \(VoiceSetup.shared.engine?.rawValue ?? "none"), model \(VoiceSetup.shared.model.map { "\($0.state)" } ?? "none")",
        ]
        #if os(macOS)
        lines.append("Beta updates: \(UserDefaults.standard.bool(forKey: MacUpdates.betaKey))")
        #endif
        for (name, error) in [("Pairing", model.pairingError), ("Devices", model.devicesError), ("Automations", model.cronsError)] {
            if let error { lines.append("\(name) error: \(error)") }
        }
        lines.append("")
        lines.append("Log (this launch):")
        lines += await Task.detached { log() }.value
        return lines.joined(separator: "\n")
    }

    /// The app's own entries since launch, plus errors from the frameworks it uses.
    private nonisolated static func log() -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            return try store.getEntries()
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == subsystem || $0.level == .error || $0.level == .fault }
                .suffix(500)
                .map { "\($0.date.ISO8601Format()) [\($0.subsystem) \($0.category)] \($0.composedMessage)" }
        } catch {
            return ["Couldn’t read the log: \(error.localizedDescription)"]
        }
    }

    private static func notificationName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not asked"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "\(status.rawValue)"
        }
    }

    private static var hardware: String {
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var bytes = [UInt8](repeating: 0, count: size)
        sysctlbyname(key, &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Copies the report and says so for a moment.
struct CopyDiagnosticsButton: View {
    let model: AppModel
    @State private var copied = false

    var body: some View {
        Button(copied ? String(localized: "Copied") : String(localized: "Copy Diagnostics")) {
            Task {
                await Diagnostics.copy(model)
                copied = true
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }
}
