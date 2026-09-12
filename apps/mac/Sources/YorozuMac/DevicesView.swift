import AppKit
import SwiftUI
import YorozuShared

/// The devices this Mac answers, and the way to add another. The list comes from the runtime
/// over the local socket (`device_list`), which is the same `devices.json` the sidecar seals
/// for; pairing mints a fresh one-time token and shows it as a QR and a string.
struct DevicesView: View {
    @ObservedObject var sidecar: Sidecar
    @State private var pairing = false

    private var model: ChatModel { LocalChat.model }

    /// A paired phone, not this Mac's own client: only those are ours to revoke.
    private func removable(_ device: DeviceInfo) -> Bool { device.via == .relay }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Devices").font(.headline)
                Spacer()
                Text(sidecar.state).font(.caption).foregroundStyle(.secondary)
            }

            if model.devices.isEmpty {
                Text("No devices yet. Pair your phone to chat with this Mac from it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            List(model.devices) { device in
                HStack(spacing: 8) {
                    Image(systemName: device.via == .local ? "laptopcomputer" : "iphone")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.shortId).font(.system(.body, design: .monospaced))
                        Text(subtitle(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: device.online ? "circle.fill" : "circle")
                        .foregroundStyle(device.online ? .green : .secondary)
                        .accessibilityLabel(device.online ? "online" : "offline")
                    if removable(device) {
                        Button("Remove", role: .destructive) { model.removeDevice(device.pub) }
                    }
                }
            }
            .frame(minHeight: 160)

            Button("Pair Another Device…") {
                sidecar.newCode()
                pairing = true
            }
            Text("Removing a device forgets its key here and at the relay: it has to pair again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Online is "has said something recently", so the list goes stale on its own; the
        // runtime pushes a new one whenever a device comes or goes.
        .task {
            while !Task.isCancelled {
                model.requestDevices()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(isPresented: $pairing) { PairingSheet(sidecar: sidecar, done: { pairing = false }) }
    }

    private func subtitle(_ device: DeviceInfo) -> String {
        if device.via == .local { return "This Mac" }
        if device.online { return "Online now" }
        guard device.lastSeen > 0 else { return "Paired" }
        let seen = Date(timeIntervalSince1970: device.lastSeen / 1000)
        return "Last seen \(seen.formatted(.relative(presentation: .named)))"
    }
}

/// The pairing payload, as a QR to scan and a string to paste. One sheet rather than a tab:
/// pairing is something you do once per device, not a setting.
struct PairingSheet: View {
    @ObservedObject var sidecar: Sidecar
    var done: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Pair a device").font(.headline)
            if let qr = sidecar.qr {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("Pairing QR code")
                Text("Scan from the Yorozu iOS app.").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("Waiting for the runtime…").frame(height: 220)
            }
            if let code = sidecar.pairingString {
                // A field bound to a constant: selectable and scrollable, edits go nowhere.
                HStack {
                    TextField("", text: .constant(code))
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Pairing code")
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                }
                Text("Or paste this code into the app.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("New code") { sidecar.newCode() }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
