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
    @State private var betaUpdates = Updates.beta

    var body: some View {
        Form {
            Section("This Mac") {
                Picker("Role", selection: Binding(get: { session.role ?? .host }, set: { session.select($0) })) {
                    Text("Host Yorozu here").tag(MacRole.host)
                    Text("Connect to another Mac").tag(MacRole.client)
                }
                .pickerStyle(.segmented)
                if session.role == .client {
                    if session.relay == nil {
                        TextField("Pairing code", text: $pairingCode, axis: .vertical)
                        LabeledContent("") {
                            Button("Connect") {
                                if (try? session.pair(with: pairingCode)) != nil { pairingCode = "" }
                            }
                            .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let failure = session.failure {
                            Text(failure).font(.caption).foregroundStyle(.red)
                        } else if session.model.failure != nil {
                            Text("Couldn’t connect. Generate a new pairing code and try again.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        clientConnection
                        if let pairedAt = session.pairedAt {
                            LabeledContent("Paired since", value: pairedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        LabeledContent("") {
                            Button("Unpair…", role: .destructive) { confirmingUnpair = true }
                        }
                    }
                }
            }
            .alert("Unpair this Mac?", isPresented: $confirmingUnpair) {
                Button("Unpair", role: .destructive) { session.unpair() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Yorozu will remove pairing keys and all cached chats from this Mac.")
            }
            if session.role == .host { RelayView() }
            // The one approval setting Yorozu itself still owns: the global bypass the
            // native agents read. Same toggle as the phone's; the runtime stores it.
            Section {
                Toggle("YOLO mode — skip all approvals", isOn: Binding(
                    get: { session.model.yoloMode },
                    set: { session.model.setYoloMode($0) }
                ))
            } header: {
                Text("Agent runtime")
            } footer: {
                Group {
                    if session.model.yoloMode {
                        Text("Every tool request runs without asking, including purchases, messages, commands, and deletes.")
                            .foregroundStyle(.red)
                        if let until = session.model.yoloUntil {
                            Text("until \(Date(timeIntervalSince1970: Double(until) / 1000).formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(session.role == .host
                            ? "OpenClaw owns models, tools, browser access, credentials, and approvals."
                            : "This Mac uses the OpenClaw runtime on its paired host Mac.")
                    }
                }
                .leadingFooter()
            }
            .onAppear { session.model.requestApprovalSettings() }
            if session.role == .host {
                Section {
                    KeepaliveView()
                    Toggle("Never sleep", isOn: Binding(
                        get: { neverSleep.isRunning },
                        set: { $0 ? neverSleep.start() : neverSleep.stop() }
                    ))
                } header: {
                    Text("Stay available")
                } footer: {
                    Group {
                        Text(
                            "Keep Yorozu running checks every minute and opens Yorozu again if it has died; "
                                + "quitting from the menu is still a quit. Never sleep keeps this Mac awake so "
                                + "the agent can answer your phone while you are away."
                        )
                    }
                    .leadingFooter()
                }
            }
            Section {
                LabeledContent("Version", value: versionLabel)
                AutomaticUpdatesToggle()
                if Updates.controller != nil {
                    Toggle("Receive beta updates", isOn: $betaUpdates)
                        .onChange(of: betaUpdates) { Updates.beta = betaUpdates }
                    LabeledContent("") { CheckForUpdatesButton() }
                }
            } header: {
                Text("Updates")
            } footer: {
                Group {
                    if Updates.controller != nil {
                        Text("Downloads updates in the background. Installs after this Mac’s agents finish and stay idle for 10 seconds.")
                        if betaUpdates {
                            Text("Beta builds include changes from main before a stable release. Turning beta off waits for a newer stable build.")
                        }
                    }
                }
                .leadingFooter()
            }
            Section {
                Text(ProviderMarkAttribution.notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private var clientConnection: some View {
        let failure = session.failure ?? session.model.failure
        let status = ClientConnectionStatus(
            state: session.model.state, ownerOnline: session.model.ownerOnline, failure: failure
        )
        return VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Connection", value: status.label)
            if let failure {
                Label {
                    Text(failure).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                }
                .font(.caption)
                Text("Check your network and that Yorozu is open on your host Mac. Yorozu will keep trying to reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status == .hostOffline {
                Text("Open Yorozu on your host Mac. Your conversations will reconnect when it is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status == .connecting {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Connecting to your host Mac")
            }
            if status != .connected {
                Button("Retry connection", action: session.retryConnection)
                Text("Retrying keeps your pairing and conversations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["YorozuVersionLabel"] as? String
            ?? info?["CFBundleShortVersionString"] as? String
            ?? "Development"
        guard let build = info?["YorozuVersionBuild"] as? String else { return version }
        return "\(version) (\(build))"
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
        Toggle(isOn: Binding(get: { startsAtLogin }, set: { LoginItem.set($0) })) {
            Text("Start at login")
            if !loginStatus.isEmpty {
                Text(loginStatus)
            }
        }
        .task {
            while !Task.isCancelled {
                startsAtLogin = LoginItem.isEnabled
                loginStatus = LoginItem.statusText
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Toggle("Keep Yorozu running", isOn: $keepRunning)
            .onChange(of: keepRunning) { Watchdog.isEnabled = keepRunning }
    }
}

extension View {
    /// A grouped Form on the Mac sets its footers flush right, under the controls; a sentence
    /// of explanation reads from the left, like the rows above it.
    func leadingFooter() -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
