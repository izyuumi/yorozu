import AppKit
import SwiftUI
import YorozuKeepalive
import YorozuPermissions
import YorozuShared

/// Whether one grant is in place. The onboarding wizard and the Permissions tab draw the same
/// one, so "granted" never looks like two different things.
struct PermissionBadge: View {
    let granted: Bool
    var asking = false

    var body: some View {
        if asking && !granted {
            Label("Asking macOS…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        } else {
            Label(granted ? "Granted" : "Waiting…", systemImage: granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(granted ? YorozuPalette.sage : Color.secondary)
        }
    }
}

/// One grant as a live row: what it is for, whether it is in place, a button that makes macOS
/// ask again, and the pane that grants it as a last resort.
///
/// Re-checked every two seconds while the row is on screen — there is no notification for a
/// TCC grant, and the user may be answering a prompt or flipping a switch in another window
/// as they look at this.
struct PermissionStatusRow: View {
    let permission: Permission

    @State private var granted = false
    @State private var asking = false
    @ObservedObject private var neverSleep = NeverSleep.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(permission.title).fontWeight(.medium)
                Spacer()
                if permission == .startAtLogin {
                    Toggle("Start Yorozu at login", isOn: Binding(
                        get: { granted },
                        set: { LoginItem.set($0) }
                    ))
                    .labelsHidden()
                } else if permission == .neverSleep {
                    Toggle("Keep this Mac awake", isOn: Binding(
                        get: { neverSleep.isRunning },
                        set: { $0 ? neverSleep.start() : neverSleep.stop() }
                    ))
                    .labelsHidden()
                } else {
                    PermissionBadge(granted: granted, asking: asking)
                }
            }
            Text(permission.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if permission.canPrompt || permission.settingsURL != nil {
                HStack {
                    Spacer()
                    if permission.canPrompt && !granted {
                        Button("Request") { Task { await ask() } }
                            .disabled(asking)
                    }
                    if let url = permission.settingsURL {
                        Button("Open System Settings…") { NSWorkspace.shared.open(url) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .task {
            while !Task.isCancelled {
                granted = await permission.isGranted()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func ask() async {
        asking = true
        granted = await permission.request()
        asking = false
    }
}

private struct PermissionSection: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let permissions: [Permission]

    static let all = [
        PermissionSection(
            id: "availability",
            title: String(localized: "Stay available"),
            detail: String(localized: "Keep Yorozu reachable from your iPhone, including after login and while you are away."),
            systemImage: "antenna.radiowaves.left.and.right",
            permissions: [.startAtLogin, .neverSleep]
        ),
        PermissionSection(
            id: "control",
            title: String(localized: "Control this Mac"),
            detail: String(localized: "See and operate apps when you ask Yorozu to do something on your Mac."),
            systemImage: "macwindow.on.rectangle",
            permissions: [.accessibility, .inputMonitoring, .screenRecording, .automation]
        ),
        PermissionSection(
            id: "files",
            title: String(localized: "Files"),
            detail: String(localized: "Work with documents, downloads, cloud drives, and app data."),
            systemImage: "folder",
            permissions: [.files, .fullDiskAccess]
        ),
        PermissionSection(
            id: "personal",
            title: String(localized: "Apps and personal data"),
            detail: String(localized: "Use only the services you want Yorozu to help with."),
            systemImage: "person.crop.circle.badge.checkmark",
            permissions: [.calendars, .reminders, .contacts, .photos, .music, .location, .camera, .microphone]
        ),
    ]
}

/// Grants grouped by what they enable, with availability first because remote access depends
/// on it even when every privacy grant is already in place.
struct PermissionsView: View {
    enum Scope { case onboarding, all }

    var showSetupButton = true
    var scope: Scope = .all

    private var sections: [PermissionSection] {
        scope == .onboarding ? Array(PermissionSection.all.prefix(2)) : PermissionSection.all
    }

    var body: some View {
        Form {
            ForEach(sections) { section in
                Section {
                    ForEach(section.permissions, id: \.self) { permission in
                        PermissionStatusRow(permission: permission)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(section.title, systemImage: section.systemImage)
                        Text(section.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if showSetupButton {
                Section {
                    LabeledContent("Setup wizard") {
                        Button("Run Again…") { OnboardingWindow.show() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
    }
}
