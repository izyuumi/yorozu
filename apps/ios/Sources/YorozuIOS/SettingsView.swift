import SwiftUI
import UIKit
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
    return host.model.link.state.label
}

/// The colour ``hostStatus(_:)`` is drawn in. An update the Mac needs is attention, not failure.
@MainActor
private func statusTint(_ host: HostSession) -> Color {
    if case .updateRequired = host.model.compatibility { return YorozuPalette.warning }
    return host.model.link.state.tint
}

struct SettingsView: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var addingHost = false
    @State private var repairHostID: HostID?
    @State private var reregistered = false

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
                                HStack(spacing: 12) {
                                    YorozuGlyphTile {
                                        Image(systemName: "desktopcomputer")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(YorozuPalette.ink)
                                    }
                                    .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.hosts.hasMultipleHosts ? host.label : String(localized: "Your Mac"))
                                            .font(.headline)
                                            .foregroundStyle(YorozuPalette.ink)
                                        YorozuStatusLabel(hostStatus(host), tint: statusTint(host))
                                            .font(.subheadline)
                                    }
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        Button("Add host", systemImage: "plus") {
                            repairHostID = nil
                            addingHost = true
                        }
                    }
                    .listRowBackground(YorozuPalette.paper)
                }
                if !session.isDemo {
                    Section {
                        Button {
                            session.reregisterPush()
                            reregistered = true
                        } label: {
                            LabeledContent("Re-register push notifications") {
                                if reregistered { Image(systemName: "checkmark").foregroundStyle(YorozuPalette.sage) }
                            }
                        }
                    } header: {
                        Text("Notifications")
                    } footer: {
                        Text("Try this if notifications stop arriving or arrive twice.")
                    }
                    .listRowBackground(YorozuPalette.paper)
                }
                if let failure = session.failure {
                    Section { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                        .listRowBackground(YorozuPalette.paper)
                }
                Section {
                    HStack(spacing: 12) {
                        YorozuGlyphTile { YorozuMark(dimension: 22) }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Yorozu")
                                .font(.headline)
                                .fontDesign(.serif)
                                .foregroundStyle(YorozuPalette.ink)
                            Text("Version \(Self.version)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(YorozuPalette.ink.opacity(0.62))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    Link(destination: URL(string: "https://github.com/izyuumi/yorozu")!) {
                        Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("App")
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
            .paperList()
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
                    YorozuStatusLabel(hostStatus(host), tint: statusTint(host))
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
            Section {
                Button("Retry connection") { host.model.start(); host.model.reconnect() }
                    .disabled(host.model.canDeliver)
                Button("Copy diagnostics", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = ConnectionDiagnostics.snapshot(for: host.model)
                    AccessibilityNotification.Announcement("Diagnostics copied").post()
                }
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
        .paperList()
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

    /// Off, or on with its expiry. Pairing is the grant, so the switch applies at once.
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
            Text("Uses each agent’s approval settings.")
        }
    }
}
