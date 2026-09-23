import SwiftUI
import YorozuKeepalive
import YorozuShared

/// Yorozu transport and app lifecycle. Agent, model, tool, browser, and credential settings
/// belong to OpenClaw and intentionally do not appear here.
struct GeneralView: View {
    @ObservedObject private var neverSleep = NeverSleep.shared
    @State private var session = MacChatSession.shared
    @State private var pairingCode = ""
    @State private var confirmingUnpair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("This Mac").font(.headline)
                Picker("Role", selection: Binding(get: { session.role ?? .host }, set: { session.select($0) })) {
                    Text("Host Yorozu here").tag(MacRole.host)
                    Text("Connect to another Mac").tag(MacRole.client)
                }
                .pickerStyle(.segmented)
                if session.role == .client {
                    if session.relay == nil {
                        TextField("Paste pairing code", text: $pairingCode, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            if (try? session.pair(with: pairingCode)) != nil { pairingCode = "" }
                        }
                        .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let failure = session.failure {
                            Text(failure).font(.caption).foregroundStyle(.red)
                        } else if session.model.failure != nil {
                            Text("Couldn’t connect. Generate a new pairing code and try again.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        LabeledContent("Connection", value: session.model.state == .paired ? "Connected" : "Connecting…")
                        if let pairedAt = session.pairedAt {
                            LabeledContent("Paired since", value: pairedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("Unpair", role: .destructive) { confirmingUnpair = true }
                    }
                }
            }
            .alert("Unpair this Mac?", isPresented: $confirmingUnpair) {
                Button("Unpair", role: .destructive) { session.unpair() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Yorozu will remove pairing keys and all cached chats from this Mac.")
            }
            if session.role == .host {
                RelayView()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent runtime").font(.headline)
                Text(session.role == .host
                    ? "OpenClaw owns models, tools, browser access, credentials, and approvals."
                    : "This Mac uses the OpenClaw runtime on its paired host Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The one approval setting Yorozu itself still owns: the global bypass the
            // native agents read. Same toggle as the phone's; the runtime stores it.
            VStack(alignment: .leading, spacing: 4) {
                Toggle("YOLO mode — skip all approvals", isOn: Binding(
                    get: { session.model.yoloMode },
                    set: { session.model.setYoloMode($0) }
                ))
                if session.model.yoloMode {
                    Text("Every tool request runs without asking, including purchases, messages, commands, and deletes.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if let until = session.model.yoloUntil {
                        Text("until \(Date(timeIntervalSince1970: Double(until) / 1000).formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { session.model.requestApprovalSettings() }
            if session.role == .host { KeepaliveView() }
            if session.role == .host { VStack(alignment: .leading, spacing: 4) {
                Toggle("Never sleep", isOn: Binding(
                    get: { neverSleep.isRunning },
                    set: { $0 ? neverSleep.start() : neverSleep.stop() }
                ))
                Text("Keeps this Mac awake so the agent can answer your phone while you are away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } }
            LabeledContent("Version", value: versionLabel)
                .foregroundStyle(.secondary)
            AutomaticUpdatesToggle()
            CheckForUpdatesButton()
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider marks").font(.headline)
                Text(ProviderMarkAttribution.notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        return info?["YorozuVersionLabel"] as? String
            ?? info?["CFBundleShortVersionString"] as? String
            ?? "Development"
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
                        + "still a quit; supervision resumes next time Yorozu opens."
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
