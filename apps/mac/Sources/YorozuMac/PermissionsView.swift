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

    static let availability = PermissionSection(
        id: "availability",
        title: String(localized: "Stay available"),
        detail: String(localized: "Keep Yorozu reachable from your iPhone, including after login and while you are away."),
        systemImage: "antenna.radiowaves.left.and.right",
        permissions: [.startAtLogin, .neverSleep]
    )
    static let control = PermissionSection(
        id: "control",
        title: String(localized: "Control this Mac"),
        detail: String(localized: "Let Claude Code and Codex threads see and operate apps on this Mac."),
        systemImage: "macwindow.on.rectangle",
        permissions: [.accessibility, .screenRecording, .automation]
    )
    static let files = PermissionSection(
        id: "files",
        title: String(localized: "Files"),
        detail: String(localized: "Let Claude Code and Codex threads work with documents, downloads, cloud drives, and app data."),
        systemImage: "folder",
        permissions: [.files, .fullDiskAccess]
    )
}

/// Grants grouped by what they enable. They reach the Claude Code and Codex processes Yorozu
/// starts, never OpenClaw, which is its own process with its own grants. Onboarding leads with
/// availability because remote access depends on it; Settings keeps those two switches in General.
struct PermissionsView: View {
    enum Scope { case onboarding, all }

    var scope: Scope = .all

    private var sections: [PermissionSection] {
        scope == .onboarding
            ? [.availability, .control]
            : [.control, .files]
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
            if scope == .all {
                Section {
                    Text("OpenClaw runs as its own process and asks macOS for its own permissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
    }
}
