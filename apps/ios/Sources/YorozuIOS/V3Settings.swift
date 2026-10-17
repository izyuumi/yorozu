import SwiftUI
import UserNotifications
import YorozuWire

/// Whether a reply in another conversation taps the phone when its in-app notice shows. On by default.
enum NoticeHaptics {
    static let key = "noticeHaptics"
}

/// Settings (#415): this device's notifications, the host, the paired devices, and Unpair. The host-side rows (push
/// for a device, removing one) need a plugin with `devices`; without it they are not shown. A sheet on iPhone and
/// iPad, the Settings window (⌘,) on the Mac.
struct V3SettingsView: View {
    let model: V3Model
    /// Called once this device is unpaired, so a sheet can close.
    var onUnpair: () -> Void = {}

    @AppStorage(NoticeHaptics.key) private var haptics = true
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlight = true
    @State private var permission: UNAuthorizationStatus?
    @State private var removing: V3DeviceInfo?
    @State private var unpairing = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            notifications
            siri
            host
            if model.devicesAvailable { devices }
            Section {
                Button(String(localized: "Unpair This Device"), role: .destructive) { unpairing = true }
                    .disabled(!model.paired)
            } footer: {
                Text(model.devicesAvailable
                    ? "Removes this device from the host, and its keys and cached conversations from this device."
                    : "Removes the keys and cached conversations from this device. On the host, `openclaw yorozu devices remove` removes it there.")
            }
        }
        .formStyle(.grouped)
        .task(id: model.state == .ready) { model.refreshDevices() }
        // Coming back from the system's notification settings.
        .task(id: scenePhase) { permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        .confirmationDialog(String(localized: "Remove this device?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing) { device in
            Button(String(localized: "Remove"), role: .destructive) { model.removeDevice(device.id) }
        } message: { _ in
            Text("It stops reaching the host and has to pair again.")
        }
        .confirmationDialog(String(localized: "Unpair this device?"), isPresented: $unpairing, titleVisibility: .visible) {
            Button(String(localized: "Unpair"), role: .destructive) {
                onUnpair()
                Task { await model.unpairEverywhere() }
            }
        }
    }

    private var current: V3DeviceInfo? { model.devices?.first(where: \.current) }

    private var notifications: some View {
        Section {
            LabeledContent(String(localized: "Notifications"), value: permissionText)
            if permission == .denied || permission == .notDetermined {
                Button(String(localized: "Open Notification Settings")) { openNotificationSettings() }
            }
            if model.devicesAvailable, let current {
                Toggle(String(localized: "Push from the Host"), isOn: Binding(get: { current.push }, set: { model.setPush($0, for: current.id) }))
                    .disabled(model.state != .ready)
            }
            #if os(iOS)
            Toggle(String(localized: "Haptic for In-App Notices"), isOn: $haptics)
            #endif
        } header: {
            Text("Notifications")
        } footer: {
            Text("While Yorozu is open, replies in other conversations show at the top of the screen instead of as notifications.")
        }
    }

    /// What Siri and Spotlight may search (owner, 2026-10-17).
    private var siri: some View {
        Section {
            Toggle(String(localized: "Show Conversations in Siri and Search"), isOn: $spotlight)
                .onChange(of: spotlight) { Task { await SpotlightIndexer.shared?.sync() } }
        } header: {
            Text("Siri & Search")
        } footer: {
            Text("Siri and Spotlight can find conversations by their titles and recent messages. The index stays on this device and is removed when you unpair.")
        }
    }

    private var host: some View {
        Section {
            if let name = model.hostInfo?.name { LabeledContent(String(localized: "Name"), value: name) }
            if let agent = model.hostInfo?.agent { LabeledContent(String(localized: "Agent"), value: agent) }
            if let version = model.hostInfo?.hostVersion { LabeledContent(String(localized: "OpenClaw"), value: version) }
            if let app = model.hostInfo?.app { LabeledContent(String(localized: "Yorozu Plugin"), value: app) }
            LabeledContent(String(localized: "Status"), value: model.state.label)
            LabeledContent(String(localized: "Relay"), value: model.pairing.flatMap { URL(string: $0.pairing.relayUrl)?.host() } ?? "")
            LabeledContent(String(localized: "Host key"), value: model.fingerprint ?? "")
            if let at = model.pairing?.pairedAt {
                LabeledContent(String(localized: "Paired"), value: at.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text("Host")
        }
    }

    private var devices: some View {
        Section {
            if let devices = model.devices {
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                        HStack {
                            Text(device.name ?? String(localized: "Unknown device"))
                            if device.current { Text("This Device").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(Self.date(device.pairedAt), format: .dateTime.year().month().day())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .badge(device.push ? nil : Text("Push off"))
                    .swipeActions {
                        if !device.current {
                            Button(String(localized: "Remove"), role: .destructive) { removing = device }
                        }
                    }
                    .contextMenu {
                        if !device.current {
                            Button(String(localized: "Remove…"), systemImage: "trash", role: .destructive) { removing = device }
                        }
                    }
                }
            } else if model.state == .ready {
                ProgressView()
            } else {
                Text(model.state.label).foregroundStyle(.secondary)
            }
            if let error = model.devicesError {
                Text(error).foregroundStyle(YorozuPalette.warning)
            }
        } header: {
            Text("Paired Devices")
        } footer: {
            Text("A removed device stops reaching the host at once and has to pair again.")
        }
    }

    private var permissionText: String {
        switch permission {
        case .authorized, .provisional, .ephemeral: String(localized: "Allowed")
        case .denied: String(localized: "Off")
        case .notDetermined: String(localized: "Not asked yet")
        default: ""
        }
    }

    private func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(url) }
        #endif
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}

/// Settings as a sheet, with Done (iPhone, iPad).
struct V3SettingsSheet: View {
    let model: V3Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            V3SettingsView(model: model) { dismiss() }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
                }
        }
    }
}
