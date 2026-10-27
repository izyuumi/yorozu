import SwiftUI
import UserNotifications
import YorozuWire

enum NoticeHaptics {
    static let key = "noticeHaptics"
}

struct SettingsView: View {
    let model: AppModel
    var onUnpair: () -> Void = {}

    @AppStorage(NoticeHaptics.key) private var haptics = true
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlight = true
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(Accent.key) private var accent = Accent.vermilion
    #if os(macOS)
    @AppStorage(MacUpdates.betaKey) private var betaUpdates = false
    #endif
    @State private var permission: UNAuthorizationStatus?
    @State private var removing: V3DeviceInfo?
    @State private var unpairing = false
    @State private var addingDevice = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
        .sheet(isPresented: $addingDevice) { AddDeviceSheet(model: model) }
        .task(id: model.state == .ready) { model.refreshDevices() }
        .task(id: scenePhase) {
            guard !model.isDemo else { return }
            permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
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

    @ViewBuilder private var content: some View {
        #if os(macOS)
        TabView {
            tab { general }
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
            tab { deviceSections }
                .tabItem { Label(String(localized: "Devices"), systemImage: "laptopcomputer.and.iphone") }
            if !model.isDemo {
                tab { host }
                    .tabItem { Label(String(localized: "Host"), systemImage: "server.rack") }
                tab { updates }
                    .tabItem { Label(String(localized: "Updates"), systemImage: "arrow.down.circle") }
            }
        }
        #else
        Form {
            general
            deviceSections
            if !model.isDemo { host }
        }
        .formStyle(.grouped)
        #endif
    }

    #if os(macOS)
    private static let macWidth: CGFloat = 520

    private func tab(@ViewBuilder _ sections: () -> some View) -> some View {
        Form { sections() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.macWidth)
    }
    #endif

    @ViewBuilder private var general: some View {
        looks
        if model.isDemo {
            Section {
                Label(String(localized: "Demo"), systemImage: "play.rectangle")
                Text("Sample conversations and scripted replies. No host connection; changes disappear when you exit.")
                Button(String(localized: "Exit Demo")) {
                    onUnpair()
                    model.exitDemo()
                }
                .accessibilityIdentifier("demo.exit")
            }
        } else {
            notifications
            siri
        }
    }

    @ViewBuilder private var deviceSections: some View {
        if model.isDemo || model.devicesAvailable { devices }
        if !model.isDemo {
            Section {
                Button(String(localized: "Unpair This Device"), role: .destructive) { unpairing = true }
                    .disabled(!model.paired)
            } footer: {
                Text(model.devicesAvailable
                    ? "Removes this device from the host, and its keys and cached conversations from this device."
                    : "Removes the keys and cached conversations from this device. On the host, `openclaw yorozu devices remove` removes it there.")
            }
        }
    }

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

    private var looks: some View {
        Section {
            Picker(String(localized: "Appearance"), selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appearance")
            LabeledContent(String(localized: "Accent Color")) {
                Text(accent.name).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: controlTarget), spacing: LayoutMetrics.inner)], spacing: LayoutMetrics.inner) {
                ForEach(Accent.allCases) { choice in
                    AccentSwatch(accent: choice, selected: choice == accent) {
                        withAnimation(.snappy) { accent = choice }
                    }
                }
            }
            .padding(.vertical, LayoutMetrics.tight)
        } header: {
            Text("Appearance")
        }
    }

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

    #if os(macOS)
    private var updates: some View {
        Section {
            Toggle(String(localized: "Beta Updates"), isOn: $betaUpdates)
                .onChange(of: betaUpdates) { MacUpdates.betaChanged() }
        } header: {
            Text("Updates")
        } footer: {
            Text("Beta builds have the newest changes before a stable release. Turned off, Yorozu waits for the next stable release.")
        }
    }
    #endif

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
                        if !model.isDemo, !device.current {
                            Button(String(localized: "Remove"), role: .destructive) { removing = device }
                        }
                    }
                    .contextMenu {
                        if !model.isDemo, !device.current {
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
            if model.inviteAvailable {
                Button(String(localized: "Add a Device…"), systemImage: "plus") { addingDevice = true }
                    .disabled(model.state != .ready)
            }
        } header: {
            Text("Paired Devices")
        } footer: {
            if model.isDemo {
                Text("This fictional device is for preview only. No host is paired.")
            } else {
                Text("A removed device stops reaching the host at once and has to pair again.")
            }
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

private struct AccentSwatch: View {
    let accent: Accent
    let selected: Bool
    let pick: () -> Void
    private let circle: CGFloat = 30

    var body: some View {
        Button(action: pick) {
            Circle()
                .fill(accent.tint)
                .frame(width: circle, height: circle)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.background)
                    }
                }
                .padding(LayoutMetrics.tight / 2)
                .overlay { Circle().strokeBorder(accent.tint, lineWidth: 2).opacity(selected ? 1 : 0) }
                .frame(width: controlTarget, height: controlTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accent.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView(model: model) { dismiss() }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
                }
        }
    }
}
