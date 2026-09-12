import SwiftUI

/// Everything that is one setting on its own: the relay, the browser, staying awake, updates.
/// The relay and the browser each used to be a tab; neither is more than a field.
struct GeneralView: View {
    @ObservedObject private var neverSleep = NeverSleep.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RelayView()
            BrowserView()
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
