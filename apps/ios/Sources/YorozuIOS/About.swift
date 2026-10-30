import SwiftUI
#if os(macOS)
import Sparkle
#endif

enum AboutLinks {
    static let website = URL(string: "https://yorozu.yumi.to")!
    static let privacy = URL(string: "https://yorozu.yumi.to/privacy")!
    static let source = URL(string: "https://github.com/izyuumi/yorozu")!

    @ViewBuilder static var all: some View {
        Link(String(localized: "Website"), destination: website)
        Link(String(localized: "Privacy Policy"), destination: privacy)
        Link(String(localized: "Source Code"), destination: source)
    }
}

/// Settings > About on iPhone and iPad.
struct AboutSections: View {
    let model: AppModel

    var body: some View {
        Section {
            LabeledContent(String(localized: "Version"), value: Diagnostics.version)
            AboutLinks.all
        }
        Section {
            CopyDiagnosticsButton(model: model)
        } footer: {
            Text("Copies the app version, device, connection state and this launch’s log, without keys or messages. Paste it into a message to the developer.")
        }
    }
}

#if os(macOS)
/// The Mac's About tab: the app, its links and diagnostics, and Sparkle's update settings.
struct MacAboutTab: View {
    let model: AppModel
    private let iconSize: CGFloat = 128

    var body: some View {
        VStack(spacing: LayoutMetrics.section) {
            HStack(alignment: .top, spacing: LayoutMetrics.section) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                    Text("Yorozu for macOS").textStyle(.title3, weight: .semibold)
                    Text("Version \(Diagnostics.version)").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: LayoutMetrics.tight) { AboutLinks.all }
                        .padding(.top, LayoutMetrics.inner)
                }
            }
            VStack(spacing: LayoutMetrics.inner) {
                CopyDiagnosticsButton(model: model)
                Text("Copies the app version, Mac, connection state and this launch’s log, without keys or messages. Paste it into a message to the developer.")
                    .textStyle(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !model.isDemo, let updater = MacUpdates.controller?.updater {
                Divider()
                UpdateSettings(updater: updater)
            }
        }
        .padding(LayoutMetrics.section)
        .frame(width: LayoutMetrics.settingsWidth)
    }
}

private struct UpdateSettings: View {
    let updater: SPUUpdater
    @AppStorage(MacUpdates.betaKey) private var betaUpdates = false
    @State private var autoCheck = false
    @State private var autoInstall = false
    @State private var canCheck = false
    private let status = MacUpdates.status

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                Toggle(String(localized: "Automatically Check for Updates"), isOn: $autoCheck)
                    .onChange(of: autoCheck) { updater.automaticallyChecksForUpdates = autoCheck }
                Toggle(String(localized: "Install Updates Automatically"), isOn: $autoInstall)
                    .onChange(of: autoInstall) { updater.automaticallyDownloadsUpdates = autoInstall }
                    .disabled(!autoCheck)
                Picker(String(localized: "Update to:"), selection: $betaUpdates) {
                    Text("Stable Versions").tag(false)
                    Text("Beta Versions").tag(true)
                }
                .fixedSize()
                .onChange(of: betaUpdates) { MacUpdates.betaChanged() }
                .help(String(localized: "Beta builds have the newest changes before a stable release."))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: LayoutMetrics.tight) {
                Button(String(localized: "Check Now")) { MacUpdates.checkForUpdates() }
                    .disabled(!canCheck)
                if let last = status.lastCheck {
                    Text("Last check: \(last.formatted(date: .numeric, time: .shortened))").foregroundStyle(.secondary)
                }
                if let message = status.message {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
        .onAppear {
            autoCheck = updater.automaticallyChecksForUpdates
            autoInstall = updater.automaticallyDownloadsUpdates
            if status.lastCheck == nil { status.lastCheck = updater.lastUpdateCheckDate }
        }
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
#endif
