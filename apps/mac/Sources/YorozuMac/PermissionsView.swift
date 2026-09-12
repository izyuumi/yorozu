import AppKit
import SwiftUI

/// Whether one grant is in place. The onboarding wizard and the Permissions tab draw the same
/// one, so "granted" never looks like two different things.
struct PermissionBadge: View {
    let granted: Bool

    var body: some View {
        Label(granted ? "Granted" : "Waiting…", systemImage: granted ? "checkmark.circle.fill" : "circle.dotted")
            .foregroundStyle(granted ? .green : .secondary)
    }
}

/// One grant as a live row: what it is for, whether it is in place, and the pane that grants it.
/// Re-checked every two seconds while the row is on screen — there is no notification for a TCC
/// grant, and the user is flipping it in another window as they look at this.
struct PermissionStatusRow: View {
    let permission: Permission

    @State private var granted = false
    @ObservedObject private var neverSleep = NeverSleep.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(permission.title)
                Spacer()
                if permission == .neverSleep {
                    Toggle("Keep this Mac awake", isOn: Binding(
                        get: { neverSleep.isRunning },
                        set: { $0 ? neverSleep.start() : neverSleep.stop() }
                    ))
                    .labelsHidden()
                } else {
                    PermissionBadge(granted: granted)
                }
                if permission.settingsURL != nil {
                    Button("Open System Settings", action: open)
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
                granted = permission.isGranted()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func open() {
        // Ask first: several grants show a system prompt that also registers the app in the pane.
        permission.request()
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
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
