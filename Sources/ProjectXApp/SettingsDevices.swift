import ProjectXCore
import SwiftUI

/// Settings › Devices: paired phones (rename, remove) and Pair iPhone, which mints a code only when pressed.
struct DevicesSettings: View {
    @ObservedObject var model: AppModel
    @State private var removing: RelayDeviceStatus?
    @State private var renaming: RelayDeviceStatus?
    @State private var name = ""
    @State private var pairing = false

    var body: some View {
        Form {
            Section {
                if model.relayStatus.devices.isEmpty { Text("No paired phones yet.").foregroundStyle(.secondary) }
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
            } header: { Text("Paired phones") } footer: {
                Text("Removing a phone revokes its key at the relay. It has to pair again to connect.").foregroundStyle(.secondary)
            }
            Section("Pair iPhone") {
                LabeledContent {
                    Button("Pair iPhone…") { pairing = true }.disabled(model.relay == nil)
                } label: {
                    Text("Pair a new iPhone")
                    Text(model.runtimeMode == .live ? "A code is created only when you press this. Each code works once." : "Pairing works in live mode only.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pairing) { PairPhoneView(model: model) }
        .alert("Rename iPhone", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { device in
            TextField("Name", text: $name)
            Button("Rename") { let label = name; Task { await model.relay?.rename(device.pub, label: label) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Leave it empty to use the name the phone sends.")
        }
        .confirmationDialog("Remove this iPhone?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { device in
            Button("Remove", role: .destructive) { Task { await model.relay?.removeDevice(device.pub) } }
        } message: { _ in
            Text("It loses access to this Mac and has to pair again.")
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
    /// Turns on Advanced and shows it, for the Gateway enrollment the popover's Connect… leads to.
    let showAdvanced: () -> Void
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
                } label: { Text("Every paired phone has to pair again after a change.") }
            }
            if let notice = model.nativeNotice {
                Section("Gateway") {
                    LabeledContent {
                        Button("Show Advanced") { showAdvanced() }
                    } label: {
                        Text(notice)
                        Text("Connect this Mac to the Gateway in Settings › Advanced.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { url = current }
        .onChange(of: current) { _, new in url = new }
        .confirmationDialog("Change the relay?", isPresented: $confirming) {
            Button("Change Relay", role: .destructive) { let next = url; model.writeSettings { $0.relay.url = next } }
            Button("Cancel", role: .cancel) { url = current }
        } message: {
            Text("All paired phones must pair again.")
        }
    }
}
