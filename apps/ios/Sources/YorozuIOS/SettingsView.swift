import SwiftUI
import YorozuShared

/// Amber remains readable as connection-state text on paper.
private extension ConnectionState {
    var tint: Color {
        switch self {
        case .connected: YorozuPalette.sage
        case .offline: YorozuPalette.warning
        case .reconnecting: .secondary
        }
    }
}

@MainActor
private func hostStatus(_ host: HostSession) -> String {
    if case .updateRequired = host.model.compatibility { return String(localized: "Update required") }
    return ConnectionState(state: host.model.state, ownerOnline: host.model.ownerOnline).label
}

struct SettingsView: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var addingHost = false
    @State private var repairHostID: HostID?

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["YorozuVersionLabel"] as? String ?? info?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(short) (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            List {
                if !session.isDemo {
                    Section(session.hosts.hasMultipleHosts ? "Hosts" : "Connection") {
                        ForEach(session.hosts.sessions) { host in
                            NavigationLink {
                                HostSettingsView(session: session, host: host) {
                                    repairHostID = host.id
                                    addingHost = true
                                }
                            } label: {
                                if session.hosts.hasMultipleHosts {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(host.label)
                                        Text(hostStatus(host)).font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    LabeledContent("Status", value: hostStatus(host))
                                }
                            }
                        }
                        Button("Add host", systemImage: "plus") {
                            repairHostID = nil
                            addingHost = true
                        }
                    }
                    .listRowBackground(YorozuPalette.paper)
                }
                if let failure = session.failure {
                    Section { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                        .listRowBackground(YorozuPalette.paper)
                }
                Section("App") {
                    LabeledContent("Version", value: Self.version)
                    Link("Source on GitHub", destination: URL(string: "https://github.com/izyuumi/yorozu")!)
                }
                .listRowBackground(YorozuPalette.paper)
                Section("Provider marks") {
                    Text(ProviderMarkAttribution.notice).font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(YorozuPalette.paper)
                if session.isDemo {
                    Section {
                        Button("Exit demo") { dismiss(); session.exitDemo() }
                    }
                    .listRowBackground(YorozuPalette.paper)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(YorozuPalette.canvas)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $addingHost) {
                NavigationStack {
                    PairingFlowView(onPair: { code in
                        do {
                            if let repairHostID, try QrPayload.decode(code).hostID != repairHostID {
                                return String(localized: "Scan a new pairing code from this host Mac to repair its connection.")
                            }
                            try session.pair(with: code)
                            return nil
                        } catch { return session.pendingPairing == nil ? error.localizedDescription : nil }
                    }, onDemo: {}, externalError: session.pairingFailure,
                    connecting: session.isPairing && session.pairingFailure == nil, addingHost: true)
                    .navigationTitle(repairHostID == nil ? "Add host" : "Repair connection")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { addingHost = false } } }
                    .modifier(PairingConfirmation(session: session))
                    .onChange(of: session.isPairing) { old, new in if old && !new { addingHost = false } }
                }
            }
            .modifier(PairingConfirmation(session: session, enabled: !addingHost))
        }
        .yorozuTint()
    }
}

private struct HostSettingsView: View {
    let session: Session
    let host: HostSession
    let onRepair: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @State private var removing = false
    @State private var nickname = ""

    private var status: ConnectionState { ConnectionState(state: host.model.state, ownerOnline: host.model.ownerOnline) }

    var body: some View {
        List {
            Section(session.hosts.hasMultipleHosts ? "Host" : "Connection") {
                if session.hosts.hasMultipleHosts {
                    TextField("Nickname", text: $nickname)
                        .autocorrectionDisabled()
                        .onChange(of: nickname) { _, value in session.setNickname(value, for: host.id) }
                    if let name = host.model.peerInfo?.computerName { LabeledContent("Computer name", value: name) }
                }
                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        Circle().fill(status.tint).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(hostStatus(host))
                    }
                    .foregroundStyle(status.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Relay")
                    Text(host.relayURL)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                LabeledContent("Mac key", value: QrPayload.fingerprint(ofBase64URLKey: host.id) ?? host.id)
                if let date = PairingStore.load(hostID: host.id)?.pairedAt {
                    LabeledContent("Paired since", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .listRowBackground(YorozuPalette.paper)
            Section("Compatibility") {
                switch host.model.compatibility {
                case .legacy:
                    Text(session.hosts.hasMultipleHosts ? "Compatible legacy host" : "Compatible")
                    Text(session.hosts.hasMultipleHosts
                         ? "Chat is available. Update this Mac to share its computer name and newer features."
                         : "Chat is available. Update Yorozu on your Mac for newer features.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .compatible(let version, _):
                    LabeledContent("Protocol", value: String(version))
                case .updateRequired(let reason):
                    Label("Update required", systemImage: "arrow.down.circle")
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
                if let version = host.model.peerInfo?.appVersion { LabeledContent(session.hosts.hasMultipleHosts ? "Host version" : "Mac version", value: version) }
            }
            .listRowBackground(YorozuPalette.paper)
            Section {
                Toggle("Skip approvals for all agents", isOn: Binding(get: { host.model.yoloMode }, set: host.model.setYoloMode))
            } header: { Text("Approvals") } footer: {
                approvalsFooter
            }
            .listRowBackground(YorozuPalette.paper)
            TerminalAccessSettings(model: host.model)
                .listRowBackground(YorozuPalette.paper)
            Section {
                Button("Repair connection", action: onRepair)
                Button(session.hosts.hasMultipleHosts ? "Remove host" : "Remove connection", role: .destructive) {
                    confirmingRemoval = true
                }.disabled(removing)
            } footer: {
                if session.hosts.hasMultipleHosts {
                    Text("Nickname is stored on this device. Clear it to use the Mac's computer name.")
                }
            }
            .listRowBackground(YorozuPalette.paper)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
        .navigationTitle(session.hosts.hasMultipleHosts ? host.label : "Connection")
        .onAppear { nickname = host.nickname ?? ""; host.model.requestApprovalSettings() }
        .alert(session.hosts.hasMultipleHosts ? "Remove \(host.label)?" : "Remove connection?", isPresented: $confirmingRemoval) {
            Button(session.hosts.hasMultipleHosts ? "Remove host" : "Remove connection", role: .destructive) {
                removing = true
                Task {
                    await session.removeHost(host.id)
                    removing = false
                    if session.hosts.session(for: host.id) == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.hosts.hasMultipleHosts
                 ? "This removes this host's keys, cached chats, queued sends, and notifications from this device. Scan a new pairing code to connect again."
                 : "This removes pairing keys, cached chats, queued sends, and notifications from this device. Scan a new pairing code to connect again.")
        }
        .yorozuTint()
    }

    /// Pending permission is distinct from an enabled approval bypass.
    @ViewBuilder private var approvalsFooter: some View {
        if host.model.yoloMode {
            Label {
                Text("Every tool request runs without asking, including purchases, messages, commands, and deletes.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let until = host.model.yoloUntil {
                Text("Until \(Date(timeIntervalSince1970: Double(until) / 1000).formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        } else {
            if host.model.yoloPending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for the Mac to allow it")
                }
                .accessibilityElement(children: .combine)
            }
            Text("Uses each agent’s approval settings. Turning this on requests permission from your host Mac.")
        }
    }
}
