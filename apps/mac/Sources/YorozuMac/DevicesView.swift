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
    @State private var expandedDeviceIDs: Set<String> = []

    private var model: ChatModel { MacChatSession.shared.model }

    /// A paired remote device, not this Mac's own client: only those are ours to revoke.
    private func removable(_ device: DeviceInfo) -> Bool { device.via == .relay }
    private func isMac(_ device: DeviceInfo) -> Bool {
        device.via == .local || device.name?.hasPrefix("macOS") == true
    }

    var body: some View {
        Form {
            Section {
                if model.devices.isEmpty {
                    Text("No devices yet. Pair your phone to chat with this Mac from it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: isMac(device) ? "laptopcomputer" : device.name?.hasPrefix("iPadOS") == true ? "ipad" : "iphone")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .accessibilityLabel(isMac(device) ? "Mac" : device.name?.hasPrefix("iPadOS") == true ? "iPad" : "Phone")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.via == .local ? "This Mac" : device.name ?? device.shortId)
                                .font(.body)
                            Button {
                                if !expandedDeviceIDs.insert(device.pub).inserted {
                                    expandedDeviceIDs.remove(device.pub)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: expandedDeviceIDs.contains(device.pub) ? "chevron.down" : "chevron.right")
                                        .font(.caption2)
                                        .accessibilityHidden(true)
                                    Text("Device ID: \(device.shortId)")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .accessibilityValue(expandedDeviceIDs.contains(device.pub) ? Text("Expanded") : Text("Collapsed"))
                            if expandedDeviceIDs.contains(device.pub) {
                                Text(device.pub)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(subtitle(device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(device.online ? YorozuPalette.sage : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .accessibilityLabel(device.online ? "online" : "offline")
                        if removable(device) {
                            Button("Remove…", role: .destructive) { confirmingRemoval = device }
                                .accessibilityLabel("Remove device \(device.shortId)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("Devices")
                    Spacer()
                    Button("Pair Another Device…") {
                        sidecar.newCode()
                        pairing = true
                    }
                }
            } footer: {
                Group {
                    Text("Removing a device forgets its key here and at the relay: it has to pair again.")
                }
                .leadingFooter()
            }
            Section("Relay") {
                LabeledContent("Status", value: sidecar.state)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
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
                done: { pairing = false }
            )
            // Esc closes a sheet on the Mac; a sheet with no Cancel button has to say so itself.
            .onExitCommand { pairing = false }
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
        } message: { device in
            Text("Remove paired device \(device.shortId)? Device ID: \(device.pub)\n\nThis device will lose access to this Mac and must pair again to reconnect.")
        }
    }

    private func subtitle(_ device: DeviceInfo) -> String {
        if device.via == .local { return "Connected locally" }
        let status: String
        if device.online { status = "Online now" }
        else if device.lastSeen > 0 {
            let seen = Date(timeIntervalSince1970: device.lastSeen / 1000)
            status = "Last seen \(seen.formatted(.relative(presentation: .named)))"
        } else { status = "Paired" }
        return device.name == nil ? status : "\(status) · \(device.shortId)"
    }
}

/// The pairing payload, as a QR to scan and a string to paste. One sheet rather than a tab:
/// pairing is something you do once per device, not a setting.
struct PairingSheet: View {
    @ObservedObject var sidecar: Sidecar
    var done: () -> Void
    var autoDismiss = true
    var onPaired: () -> Void = {}
    var showsActions = true
    /// Inside the setup window, which supplies its own title, width and padding.
    var embedded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paired = false
    @State private var progress = DevicePairingProgress()
    @State private var preparationFailed = false
    @State private var attempt = 0

    private var model: ChatModel { MacChatSession.shared.model }

    var body: some View {
        VStack(spacing: 16) {
            if paired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(YorozuPalette.sage)
                    .accessibilityHidden(true)
                Text("Device paired").font(.headline)
                Text("It can reach this Mac now. Whether an agent answers depends on what is set up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                if !embedded { Text("Pair a device").font(.headline) }
                if progress.baseline == nil {
                    VStack(spacing: 8) {
                        if preparationFailed {
                            Text("Couldn’t load paired devices").font(.headline)
                            Text("Check the connection in General settings, then try again.")
                                .font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try again") { attempt += 1 }
                        } else {
                            ProgressView("Checking paired devices…")
                        }
                    }
                    .frame(height: 220)
                } else if let qr = sidecar.qr {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("Pairing QR code")
                    Text("Scan with Yorozu on your iPhone or iPad.").font(.caption).foregroundStyle(.secondary)
                } else {
                    if sidecar.state == "stopped" || sidecar.state == "closed"
                        || sidecar.state.hasPrefix("restarting") || sidecar.state.hasPrefix("failed") {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                                .font(.largeTitle)
                            Text("Pairing is temporarily unavailable").font(.headline)
                            Text("Check the connection in General settings. When Yorozu reconnects, request a new code.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(height: 220)
                    } else if sidecar.pairingString == nil {
                        ProgressView("Preparing a pairing code…").frame(height: 220)
                    } else {
                        Text("Use the pairing code below to connect your device.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if progress.baseline != nil, let code = sidecar.pairingString {
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
                    // Codes are not revoked by minting another: the runtime and the relay keep
                    // recent ones until they expire, so "keep it private" is the whole advice.
                    Text("Or paste it into Connect to another Mac on a Mac, or Enter code manually on an iPhone or iPad. Codes work once and expire; keep this one private.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if showsActions {
                    HStack {
                        Button("New code") { sidecar.newCode() }
                            .disabled(progress.baseline == nil)
                        Spacer()
                        Button("Close", action: done).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 380)
        .frame(minHeight: 180)
        // A sheet of its own sits on paper like every other card; embedded, it takes its host's.
        .background(embedded ? Color.clear : YorozuPalette.paper)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: paired)
        .task(id: attempt) {
            // Do not expose a code until a fresh list establishes which devices already exist.
            // Once visible, freeze that baseline: even an immediate pairing must count.
            preparationFailed = false
            let revision = model.deviceListRevision
            model.requestDevices()
            let deadline = Date().addingTimeInterval(10)
            while model.deviceListRevision == revision, !Task.isCancelled {
                guard Date() < deadline else {
                    preparationFailed = true
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            progress.establishBaseline(model.devices)
            sidecar.newCode()
            while !Task.isCancelled, !paired {
                model.requestDevices()
                if progress.newlyPaired(in: model.devices) {
                    paired = true
                    onPaired()
                    if autoDismiss {
                        do { try await Task.sleep(for: .seconds(1.2)) }
                        catch { return }
                        done()
                    }
                    return
                }
                do { try await Task.sleep(for: .seconds(0.5)) }
                catch { return }
            }
        }
    }
}
