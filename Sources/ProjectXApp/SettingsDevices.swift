import ProjectXCore
import SwiftUI

/// Settings › Devices: paired phones (rename, remove) and Pair iPhone, which mints a code only when pressed.
struct DevicesSettings: View {
    @ObservedObject var model: AppModel
    @State private var removing: RelayDeviceStatus?
    @State private var renaming: RelayDeviceStatus?
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                if model.relayStatus.devices.isEmpty { Text("No client devices yet.").foregroundStyle(.secondary) }
                ForEach(model.relayStatus.devices) { device in
                    LabeledContent {
                        Button("Rename…") { name = device.label ?? device.name ?? ""; renaming = device }
                            .accessibilityLabel("Rename \(device.displayName)")
                        Button("Remove…", role: .destructive) { removing = device }
                            .accessibilityLabel("Remove \(device.displayName)")
                    } label: {
                        Label(device.displayName, systemImage: "iphone")
                        Text(Self.detail(device))
                    }
                }
            } header: { Text("Client devices") } footer: {
                Text("Removing a client device revokes its key at the relay. It has to pair again to connect.").foregroundStyle(.secondary)
            }
            Section("Pair a Client Device") {
                LabeledContent {
                    Button("Pair a Client Device…") { model.pairingSheet = true }.disabled(model.relay == nil)
                } label: {
                    Text("Pair a new client device")
                    Text(model.runtimeMode == .live ? "A code is created only when you press this. Each code works once." : "Pairing works in live mode only.")
                }
            }
        }
        .settingsForm()
        .sheet(isPresented: $model.pairingSheet) { PairPhoneView(model: model) }
        .alert("Rename Client Device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { device in
            TextField("Name", text: $name)
            Button("Rename") { let label = name; Task { await model.relay?.rename(device.pub, label: label) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Leave it empty to use the name the device sends.")
        }
        .confirmationDialog("Remove this client device?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { device in
            Button("Remove", role: .destructive) { Task { await model.relay?.removeDevice(device.pub) } }
        } message: { _ in
            Text("It loses access to this host and has to pair again.")
        }
    }

    /// "Online · paired 2 Oct 2026", "Last seen 3 hours ago · paired …", or "Paired …".
    static func detail(_ device: RelayDeviceStatus) -> String {
        let paired = device.pairedAt.formatted(date: .abbreviated, time: .omitted)
        if device.online { return String(localized: "Online · paired \(paired)") }
        if let seen = device.lastSeen { return String(localized: "Last seen \(seen.formatted(.relative(presentation: .named))) · paired \(paired)") }
        return String(localized: "Paired \(paired)")
    }
}

/// Settings › Connection: relay status and the relay URL; a new URL means every phone pairs again.
struct ConnectionSettings: View {
    @ObservedObject var model: AppModel
    /// Turns on Advanced settings and shows Harness, for the Gateway enrollment (`AppModel.showEnrollment`, which Connect… in the popover also uses).
    let showHarness: () -> Void
    @State private var url = ""
    @State private var confirming = false

    var body: some View {
        let current = model.config.relay.url, locked = model.override("relay.url")
        let valid = URLComponents(string: url).map { ["ws", "wss"].contains($0.scheme ?? "") && !($0.host ?? "").isEmpty } ?? false
        Form {
            ConfigProblems(model: model)
            Section("Relay") {
                LabeledContent("Status") {
                    Text(model.runtimeMode == .live ? model.relayStatus.state : String(localized: "The relay runs in live mode only.")).textSelection(.enabled)
                }
                TextField(text: $url) {
                    Text("Relay URL")
                    if let note = overrideNote(locked) { note } else if !url.isEmpty, !valid { Text("Expected a ws:// or wss:// address.") }
                }
                .disabled(locked != nil)
                .onSubmit { if valid, url != current { confirming = true } }
                LabeledContent {
                    Button("Change Relay…") { confirming = true }.disabled(locked != nil || !valid || url == current)
                } label: { Text("Every client device has to pair again after a change.") }
            }
            if model.runtimeMode == .live { DirectDiagnostics(status: model.relayStatus) }
            if let notice = model.nativeNotice {
                Section("Gateway") {
                    LabeledContent {
                        Button("Show Harness") { showHarness() }
                    } label: {
                        Text(notice)
                        Text("Connect this Mac to the Gateway in Settings › Harness.")
                    }
                }
            }
        }
        .settingsForm()
        .onAppear { url = current }
        .onChange(of: current) { _, new in url = new }
        .confirmationDialog("Change the relay?", isPresented: $confirming) {
            Button("Change Relay", role: .destructive) { let next = url; model.writeSettings { $0.relay.url = next } }
            Button("Cancel", role: .cancel) { url = current }
        } message: {
            Text("All client devices must pair again.")
        }
    }
}

/// Settings › Connection › Direct connection (#315): the listener, the addresses phones are told, and each
/// phone's route. `[direct] enabled` and `port` live in config.toml.
struct DirectDiagnostics: View {
    let status: RelayStatus

    var body: some View {
        let direct = status.direct
        Section {
            LabeledContent("Listener") { Text(Self.listener(direct)).textSelection(.enabled) }
            LabeledContent("Addresses") {
                if direct.candidates.isEmpty { Text("None") }
                else {
                    VStack(alignment: .trailing) {
                        ForEach(direct.candidates, id: \.self) { Text(verbatim: "\($0.host) · \(Self.kind($0.kind))") }
                    }.textSelection(.enabled)
                }
            }
            ForEach(status.devices) { device in
                LabeledContent {
                    Text(device.route.map { String(localized: "Direct · \(Self.kind($0))") } ?? String(localized: "Relay"))
                } label: {
                    Text(device.displayName)
                    if let error = device.directError { Text(error) }
                }
            }
            if let refusal = direct.lastRefusal {
                LabeledContent("Last refused") { Text(refusal).textSelection(.enabled) }
            }
        } header: { Text("Direct connection") } footer: {
            Text("Client devices on the same Wi-Fi or VPN connect straight to the host once their Direct connection setting is on. Set `[direct] enabled` and `port` in config.toml.").foregroundStyle(.secondary)
        }
    }

    static func listener(_ direct: DirectStatus) -> String {
        switch direct.listener {
        case .off: String(localized: "Off")
        case .starting: String(localized: "Starting on port \(String(direct.port))…")
        case .listening: String(localized: "Listening on port \(String(direct.port))")
        case .failed(let reason): String(localized: "Not listening on port \(String(direct.port)): \(reason)")
        }
    }

    static func kind(_ kind: DirectKind) -> String {
        switch kind {
        case .lan: String(localized: "LAN")
        case .vpn: String(localized: "VPN")
        case .tailscale: String(localized: "Tailscale")
        }
    }
}
