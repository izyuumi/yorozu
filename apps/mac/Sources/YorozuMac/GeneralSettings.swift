import SwiftUI
import YorozuKeepalive
import YorozuShared

/// Yorozu transport and app lifecycle. Agent, model, tool, browser, and credential settings
/// belong to OpenClaw and intentionally do not appear here.
struct GeneralView: View {
    @ObservedObject private var neverSleep = NeverSleep.shared
    @State private var session = MacChatSession.shared
    @State private var betaUpdates = Updates.beta
    @AppStorage(ChatView.sendWithCommandReturnKey) private var sendWithCommandReturn = false

    var body: some View {
        Form {
            Section("This Mac") {
                Picker("Role", selection: Binding(get: { session.role ?? .host }, set: { session.select($0) })) {
                    Text("Host Yorozu here").tag(MacRole.host)
                    Text("Connect to another Mac").tag(MacRole.client)
                }
                .pickerStyle(.segmented)
                if session.role == .client {
                    Text(session.hosts.hasMultipleHosts ? "Manage paired Macs in Hosts." : "Manage pairing in Connection.")
                        .foregroundStyle(.secondary)
                }
            }
            if session.role == .host { RelayView() }
            Section {
                Picker("Send message with", selection: $sendWithCommandReturn) {
                    Text("Return").tag(false)
                    Text("⌘ Return").tag(true)
                }
            } header: {
                Text("Chat")
            } footer: {
                Text(sendWithCommandReturn
                    ? "Return starts a new line."
                    : "Shift-Return starts a new line.")
                    .leadingFooter()
            }
            // The one approval setting Yorozu itself still owns: the global bypass the
            // native agents read. Same toggle as the phone's; the runtime stores it.
            if session.role == .host {
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
                            Text("OpenClaw owns models, tools, browser access, credentials, and approvals.")
                        }
                    }
                    .leadingFooter()
                }
                .onAppear { session.model.requestApprovalSettings() }
                TerminalAccessSettings(model: session.model)
            }
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
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
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
