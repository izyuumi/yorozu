import AppKit
import SwiftUI
import YorozuKeepalive
import YorozuPermissions

/// One `Permission` per page, in `Permission.allCases` order.
///
/// Every page asks macOS for its grant the moment it appears, using the real API, so the
/// user answers a system prompt instead of being sent to System Settings to find a checkbox.
/// The page then polls until the answer lands and the badge turns green. "Skip" is always
/// there: a grant nobody wants is a grant the agent can ask for again later, through the
/// request_permission tool.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var index = 0
    @State private var granted = false
    @State private var asking = false
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
            } else if step == .startAtLogin {
                // Already turned on by the time this is drawn — see `.task` below. The toggle
                // is here to say so, and to let the one user in a hundred who does not want it
                // say no without hunting through System Settings.
                Toggle("Start Yorozu at login", isOn: Binding(
                    get: { granted },
                    set: { LoginItem.set($0) }
                ))
                Text(LoginItem.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if step == .neverSleep {
                Toggle("Keep this Mac awake", isOn: neverSleepBinding)
            } else {
                PermissionBadge(granted: granted, asking: asking)
            }
            Spacer()
            HStack {
                if !step.isAppSetting {
                    Button(step.canPrompt ? "Ask Again" : "Open System Settings") {
                        Task { await ask() }
                    }
                    .disabled(asking)
                    if step.canPrompt, let url = step.settingsURL {
                        Button("Open System Settings") { NSWorkspace.shared.open(url) }
                    }
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
        .frame(width: 460, height: 340)
        // Restarted on every step, so only the step on screen is asked for and polled.
        .task(id: index) {
            granted = await step.isGranted()
            // Asking for something already granted would be a prompt the user has to dismiss
            // for no reason, and for Automation a round of app launches for no reason.
            if !granted {
                // The one step that is on by default: a Mac bought to answer a phone should
                // not need this wizard run again after the first power cut. macOS shows no
                // prompt for it, so turning it on here costs the user nothing to undo.
                if step == .startAtLogin {
                    LoginItem.set(true)
                    granted = await step.isGranted()
                } else {
                    await ask()
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                granted = await step.isGranted()
            }
        }
    }

    private func ask() async {
        asking = true
        granted = await step.request()
        asking = false
    }

    private var neverSleepBinding: Binding<Bool> {
        Binding(get: { neverSleep.isRunning }, set: { $0 ? neverSleep.start() : neverSleep.stop() })
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
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
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
