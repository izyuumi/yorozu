import AppKit
import SwiftUI
import YorozuKeepalive
import YorozuPermissions

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
                .foregroundStyle(granted ? .green : .secondary)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(permission.title)
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
                if permission.canPrompt {
                    Button("Request") { Task { await ask() } }
                        .disabled(asking)
                }
                if let url = permission.settingsURL {
                    Button("Open System Settings") { NSWorkspace.shared.open(url) }
                }
            }
            Text(permission.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if permission == .approvals { ApprovalFloorView() }
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

/// The onboarding checks as a list that is always true, rather than a wizard to walk once.
struct PermissionsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Permissions").font(.headline)
                Spacer()
                Button("Run Setup Wizard…") { OnboardingWindow.show() }
            }
            ForEach(Permission.allCases) { permission in
                Divider()
                PermissionStatusRow(permission: permission)
            }
        }
    }
}
