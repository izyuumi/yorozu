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
                        LabeledContent("Connection", value: session.model.state == .paired ? "Connected" : "Connecting…")
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
                    LabeledContent("") { CheckForUpdatesButton() }
                }
            } header: {
                Text("Updates")
            } footer: {
                Group {
                    if Updates.controller != nil {
                        Text("Downloads new versions in the background and installs them while you are away.")
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
