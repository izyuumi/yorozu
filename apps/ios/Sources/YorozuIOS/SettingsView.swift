import SwiftUI
import YorozuShared

private extension ConnectionState {
    var tint: Color {
        switch self {
        case .connected: YorozuPalette.sage
        case .offline: .orange
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
                    Section("Hosts") {
                        ForEach(session.hosts.sessions) { host in
                            NavigationLink {
                                HostSettingsView(session: session, host: host) {
                                    repairHostID = host.id
                                    addingHost = true
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.label)
                                    Text(hostStatus(host)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Add host", systemImage: "plus") {
                            repairHostID = nil
                            addingHost = true
                        }
                    }
                }
                if let failure = session.failure {
                    Section { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                }
                Section("App") {
                    LabeledContent("Version", value: Self.version)
                    Link("Source on GitHub", destination: URL(string: "https://github.com/izyuumi/yorozu")!)
                }
                Section("Provider marks") {
                    Text(ProviderMarkAttribution.notice).font(.footnote).foregroundStyle(.secondary)
                }
                if session.isDemo {
                    Section {
                        Button("Exit demo") { dismiss(); session.exitDemo() }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
            Section("Host") {
                TextField("Nickname", text: $nickname)
                    .autocorrectionDisabled()
                    .onChange(of: nickname) { _, value in session.setNickname(value, for: host.id) }
                if let name = host.model.peerInfo?.computerName { LabeledContent("Computer name", value: name) }
                LabeledContent("Status") { Text(hostStatus(host)).foregroundStyle(status.tint) }
                LabeledContent("Relay", value: host.relayURL)
                LabeledContent("Mac key", value: QrPayload.fingerprint(ofBase64URLKey: host.id) ?? host.id)
                if let date = PairingStore.load(hostID: host.id)?.pairedAt {
                    LabeledContent("Paired since", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Compatibility") {
                switch host.model.compatibility {
                case .legacy:
                    Text("Compatible legacy host")
                    Text("Chat is available. Update this Mac to share its computer name and newer features.").font(.footnote).foregroundStyle(.secondary)
                case .compatible(let version, _):
                    LabeledContent("Protocol", value: String(version))
                case .updateRequired(let reason):
                    Label("Update required", systemImage: "arrow.down.circle")
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
                if let version = host.model.peerInfo?.appVersion { LabeledContent("Host version", value: version) }
            }
            Section {
                Toggle("Skip approvals for all agents", isOn: Binding(get: { host.model.yoloMode }, set: host.model.setYoloMode))
            } header: { Text("Approvals") } footer: {
                if host.model.yoloPending { Text("Waiting for the Mac to allow it") }
                if host.model.yoloMode {
                    Label("Every tool request runs without asking, including purchases, messages, commands, and deletes.", systemImage: "exclamationmark.triangle.fill")
                    if let until = host.model.yoloUntil {
                        Text("until \(Date(timeIntervalSince1970: Double(until) / 1000).formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
            Section {
                Button("Repair connection", action: onRepair)
                Button("Remove host", role: .destructive) { confirmingRemoval = true }.disabled(removing)
            } footer: { Text("Nickname is stored on this device. Clear it to use the Mac's computer name.") }
        }
        .navigationTitle(host.label)
        .onAppear { nickname = host.nickname ?? ""; host.model.requestApprovalSettings() }
        .alert("Remove \(host.label)?", isPresented: $confirmingRemoval) {
            Button("Remove host", role: .destructive) {
                removing = true
                Task {
                    await session.removeHost(host.id)
                    removing = false
                    if session.hosts.session(for: host.id) == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this host's keys, cached chats, queued sends, and notifications from this device. Scan a new pairing code to connect again.")
        }
    }
}
