import AppKit
import SwiftUI
import YorozuShared

/// The devices this Mac answers, and the way to add another. The list comes from the runtime
/// over the local socket (`device_list`), which is the same `devices.json` the sidecar seals
/// for; pairing mints a fresh one-time token and shows it as a QR and a string.
struct DevicesView: View {
    @ObservedObject var sidecar: Sidecar
    @State private var pairing = false
    @State private var confirmingRemoval: DeviceInfo?

    private var model: ChatModel { MacChatSession.shared.model }

    /// A paired phone, not this Mac's own client: only those are ours to revoke.
    private func removable(_ device: DeviceInfo) -> Bool { device.via == .relay }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
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
                        Button("Remove", role: .destructive) { confirmingRemoval = device }
                    }
                }
            }
            .listStyle(.inset)
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
        .sheet(isPresented: $pairing) {
            PairingSheet(
                sidecar: sidecar,
                existingDeviceIDs: Set(model.devices.filter(removable).map(\.pub)),
                done: { pairing = false }
            )
        }
        .confirmationDialog(
            "Remove this device?",
            isPresented: Binding(
                get: { confirmingRemoval != nil },
                set: { if !$0 { confirmingRemoval = nil } }
            ),
            presenting: confirmingRemoval
        ) { device in
            Button("Remove", role: .destructive) {
                model.removeDevice(device.pub)
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: { _ in
            Text("It will forget its key here and at the relay, and must pair again.")
        }
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
    let existingDeviceIDs: Set<String>
    var done: () -> Void
    var autoDismiss = true
    var onPaired: () -> Void = {}
    var showsActions = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paired = false

    private var model: ChatModel { MacChatSession.shared.model }

    var body: some View {
        VStack(spacing: 16) {
            if paired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Device paired").font(.headline)
                Text("Your device is connected and ready to use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
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
                    HStack {
                        Text(code)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(.separator, lineWidth: 1)
                            }
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityLabel("Pairing code")
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                    }
                    Text("Or paste this code into the app.").font(.caption).foregroundStyle(.secondary)
                }
                if showsActions {
                    HStack {
                        Button("New code") { sidecar.newCode() }
                        Spacer()
                        Button("Done", action: done).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .frame(minHeight: 180)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: paired)
        .task {
            // Establish what was already paired before looking for the device using this code.
            // A fresh host has not necessarily received its first device list yet.
            model.requestDevices()
            try? await Task.sleep(for: .milliseconds(500))
            let baseline = existingDeviceIDs.union(
                model.devices.filter { $0.via == .relay }.map(\.pub)
            )
            while !Task.isCancelled, !paired {
                model.requestDevices()
                if model.devices.contains(where: {
                    $0.via == .relay && !baseline.contains($0.pub)
                }) {
                    paired = true
                    onPaired()
                    if autoDismiss {
                        try? await Task.sleep(for: .seconds(1.2))
                        done()
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }
}
