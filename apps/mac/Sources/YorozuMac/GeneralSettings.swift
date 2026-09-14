import SwiftUI
import YorozuKeepalive

/// Yorozu transport and app lifecycle. Agent, model, tool, browser, and credential settings
/// belong to OpenClaw and intentionally do not appear here.
struct GeneralView: View {
    @ObservedObject private var neverSleep = NeverSleep.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RelayView()
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent runtime").font(.headline)
                Text("OpenClaw owns models, tools, browser access, credentials, and approvals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            KeepaliveView()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Never sleep", isOn: Binding(
                    get: { neverSleep.isRunning },
                    set: { $0 ? neverSleep.start() : neverSleep.stop() }
                ))
                Text("Keeps this Mac awake so the agent can answer your phone while you are away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AutomaticUpdatesToggle()
            CheckForUpdatesButton()
        }
    }
}

/// The two switches that decide whether Yorozu is running at all: one for a Mac that has just
/// booted, one for a Yorozu that has just died. Both default on — see ``Watchdog``.
///
/// Read back from the system rather than from a preference: macOS owns the login item, and the
/// LaunchAgent is a file on disk that the user is free to delete. Polled while the tab is open
/// because neither of those changes tells us it changed.
struct KeepaliveView: View {
    @State private var startsAtLogin = false
    @State private var loginStatus = ""
    @State private var keepRunning = Watchdog.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Start at login", isOn: Binding(
                    get: { startsAtLogin },
                    set: { LoginItem.set($0) }
                ))
                Text(loginStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep Yorozu running", isOn: $keepRunning)
                    .onChange(of: keepRunning) { Watchdog.isEnabled = keepRunning }
                Text(
                    "Checks every minute and opens Yorozu again if it has died. Quitting from the menu is "
                        + "still a quit: it holds the check off for ten minutes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                startsAtLogin = LoginItem.isEnabled
                loginStatus = LoginItem.statusText
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
