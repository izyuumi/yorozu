import AppKit
import SwiftUI

/// One `Permission` per page, in `Permission.allCases` order. Each page explains the grant,
/// deep-links to its System Settings pane, and re-checks every two seconds until it goes green.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var index = 0
    @State private var granted = false
    @State private var skipped: Set<Permission> = []
    @ObservedObject private var neverSleep = NeverSleep.shared

    private var step: Permission { Permission.allCases[index] }
    private var isLast: Bool { index == Permission.allCases.count - 1 }
    private var canContinue: Bool { granted || skipped.contains(step) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step \(index + 1) of \(Permission.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(step.title).font(.title2.bold())
            Text(step.detail)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if step == .approvals {
                ApprovalFloorView()
            } else {
                PermissionBadge(granted: granted)
            }
            Spacer()
            HStack {
                if step == .approvals {
                    EmptyView()
                } else if step == .neverSleep {
                    Toggle("Keep this Mac awake", isOn: neverSleepBinding)
                } else {
                    Button("Open System Settings", action: openSettings)
                }
                Spacer()
                Button("Skip") {
                    skipped.insert(step)
                    advance()
                }
                Button(isLast ? "Done" : "Continue", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(20)
        .frame(width: 460, height: 320)
        // Restarted on every step, so only the step on screen is polled.
        .task(id: index) {
            while !Task.isCancelled {
                granted = step.isGranted()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var neverSleepBinding: Binding<Bool> {
        Binding(get: { neverSleep.isRunning }, set: { $0 ? neverSleep.start() : neverSleep.stop() })
    }

    private func openSettings() {
        // Ask first: several grants show a system prompt that also registers the app in the pane.
        step.request()
        if let url = step.settingsURL { NSWorkspace.shared.open(url) }
    }

    private func advance() {
        guard !isLast else { return onFinish() }
        index += 1
        granted = false
    }
}

/// The wizard lives in a plain window: the app is an `LSUIElement` menu bar agent, so there is
/// no main scene to host it and nothing to restore it on relaunch.
@MainActor
enum OnboardingWindow {
    static let completedKey = "onboardingCompleted"

    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Yorozu Setup"
            panel.isReleasedWhenClosed = false
            panel.center()
            panel.contentViewController = NSHostingController(rootView: OnboardingView(onFinish: finish))
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func showIfFirstLaunch() {
        if !UserDefaults.standard.bool(forKey: completedKey) { show() }
    }

    private static func finish() {
        UserDefaults.standard.set(true, forKey: completedKey)
        window?.close()
    }
}
