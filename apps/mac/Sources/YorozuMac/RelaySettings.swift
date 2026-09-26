import SwiftUI
import YorozuShared

/// Which relay the sidecar talks to. One environment variable (`YOROZU_RELAY_URL`) the
/// runtime already reads; the picker is a text field because a relay is just a URL.
///
/// The default is the hosted relay, a Cloudflare Worker at `relay.yumi.to`. A LAN or
/// Tailscale relay — say `ws://100.100.1.1:8787` from
/// `scripts/install-relay-launchagent.sh` — goes in the same field.
enum RelaySettings {
    static let key = "YOROZU_RELAY_URL"
    static let defaultUrl = "wss://relay.yumi.to"

    /// The configured URL, or the default when nothing has been stored yet.
    static var url: String {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        return stored.isEmpty ? defaultUrl : stored
    }
}

struct RelayView: View {
    @AppStorage(RelaySettings.key) private var url = RelaySettings.defaultUrl

    var body: some View {
        Section {
            TextField("Relay", text: $url)
        } footer: {
            Group {
                Text("The blind relay your phone reaches this Mac through. Restart to apply.")
            }
            .leadingFooter()
        }
    }
}

/// Client-only host management. Each disclosure owns one model, including settings actions.
struct HostsView: View {
    @State private var session: MacChatSession
    @State private var pairingCode = ""
    @State private var repairCode: String?
    @State private var removingHost: HostSession?
    @State private var busy = false

    init(session: MacChatSession = .shared) { _session = State(initialValue: session) }

    var body: some View {
        Form {
            if session.hosts.sessions.isEmpty {
                Section { Text("Add a host to reach its chats from this Mac.").foregroundStyle(.secondary) }
            }
            ForEach(session.hosts.sessions) { host in
                Section {
                    DisclosureGroup {
                        HostConnectionDetails(host: host, session: session) { removingHost = host }
                            .padding(.top, 10)
                    } label: {
                        HStack {
                            if session.hosts.hasMultipleHosts {
                                Label(host.label, systemImage: "desktopcomputer")
                            } else {
                                Text("Connection")
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Circle().fill(connectionTint(host)).frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                                Text(connectionLabel(host))
                            }
                            .font(.callout)
                            .foregroundStyle(connectionTint(host))
                        }
                    }
                }
            }
            Section("Add Host") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("On the host Mac, open Settings › Devices › Pair Another Device, then paste its code here.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("Pairing code", text: $pairingCode, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("New host pairing code")
                    Button("Add Host", action: addHost)
                        .disabled(busy || pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let failure = session.failure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
        .disabled(busy)
        .alert("Already connected", isPresented: Binding(get: { repairCode != nil }, set: { if !$0 { repairCode = nil } }), presenting: repairCode) { code in
            Button("Repair connection", role: .destructive) {
                busy = true
                Task {
                    do { try await session.repair(with: code); pairingCode = "" } catch {}
                    busy = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { code in
            let pairing = try? QrPayload.decode(code)
            Text("Relay: \(pairing?.relayUrl ?? "")\nMac key: \(pairing?.macKeyFingerprint ?? "")\n\nRepair replaces this connection. Chats, drafts, and queued messages stay saved.")
            if session.hosts.hasMultipleHosts { Text("Other hosts stay connected.") }
        }
        .alert(session.hosts.hasMultipleHosts ? "Remove host?" : "Unpair this Mac?", isPresented: Binding(get: { removingHost != nil }, set: { if !$0 { removingHost = nil } }), presenting: removingHost) { host in
            Button(session.hosts.hasMultipleHosts ? "Remove Host" : "Unpair", role: .destructive) {
                busy = true
                Task { await session.removeHost(host.id); busy = false }
            }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            if session.hosts.hasMultipleHosts {
                Text("Remove \(host.label)’s pairing keys, counters, cached chats, and queued messages from this Mac? Other hosts stay connected.")
            } else {
                Text("Yorozu will remove pairing keys, counters, cached chats, and queued messages from this Mac.")
            }
        }
    }

    private func addHost() {
        do { try session.pair(with: pairingCode); pairingCode = "" }
        catch MacChatSession.PairingError.alreadyConnected { repairCode = pairingCode }
        catch {}
    }

    /// Keep main's connection indicator: the word and dot carry the state together.
    private func connectionTint(_ host: HostSession) -> Color {
        if case .updateRequired = host.model.compatibility { return YorozuPalette.warning }
        return switch ClientConnectionStatus(host.model, failure: session.hostFailures[host.id] ?? host.model.failure) {
        case .connected: YorozuPalette.sage
        case .hostOffline, .offline: YorozuPalette.warning
        case .failed: .red
        case .connecting: .secondary
        }
    }

    private func connectionLabel(_ host: HostSession) -> String {
        if case .updateRequired = host.model.compatibility { return "Update required" }
        return ClientConnectionStatus(host.model, failure: session.hostFailures[host.id] ?? host.model.failure).label
    }
}

private struct HostConnectionDetails: View {
    let host: HostSession
    let session: MacChatSession
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.hosts.hasMultipleHosts {
                LabeledContent("Nickname") {
                    TextField("Optional", text: Binding(get: { host.nickname ?? "" }, set: { session.nickname($0, for: host.id) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }
            }
            LabeledContent("Relay", value: host.relayURL).textSelection(.enabled)
            LabeledContent("Mac key", value: QrPayload.fingerprint(ofBase64URLKey: host.id) ?? host.id)
                .textSelection(.enabled)
            if let pairedAt = host.pairedAt {
                LabeledContent("Paired since", value: pairedAt.formatted(date: .abbreviated, time: .shortened))
            }
            switch host.model.compatibility {
            case .legacy:
                LabeledContent("Compatibility", value: "Legacy host · chat supported")
            case .compatible(let version, _):
                LabeledContent("Compatibility", value: "Compatible · protocol \(version)")
                if let version = host.model.peerInfo?.appVersion { LabeledContent("Host version", value: version) }
            case .updateRequired(let reason):
                Label("Update required", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if let failure = session.hostFailures[host.id] ?? host.model.failure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !host.model.canDeliver {
                Button("Retry connection") { session.retryConnection(host.id) }
                Text("Pairing and conversations stay saved while this host reconnects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("YOLO mode — skip all approvals", isOn: Binding(
                get: { host.model.yoloMode }, set: { host.model.setYoloMode($0) }))
                .disabled(!host.model.canDeliver)
            if host.model.yoloMode {
                Text("Every tool request on this host runs without asking, including purchases, messages, commands, and deletes.")
                    .font(.caption).foregroundStyle(.red)
            }
            Button(session.hosts.hasMultipleHosts ? "Remove Host…" : "Unpair…", role: .destructive, action: remove)
                .buttonStyle(.bordered)
        }
        .onAppear { host.model.requestApprovalSettings() }
    }
}
