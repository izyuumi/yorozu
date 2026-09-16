import AppKit
import SwiftUI
import YorozuShared

struct OnboardingView: View {
    enum Step { case role, hostPair, hostPermissions, clientPair, success }

    var onFinish: () -> Void
    @State private var session = MacChatSession.shared
    @State private var step: Step
    @State private var pairingCode = ""
    @State private var pairingError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: MacChatSession.shared.role == nil ? .role : .hostPermissions)
    }

    var body: some View {
        Group {
            switch step {
            case .role: roleChoice
            case .hostPair: hostPairing
            case .hostPermissions: hostPermissions
            case .clientPair: clientPairing
            case .success: success
            }
        }
        .padding(28)
        .frame(width: 560, height: 540)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step)
        .onChange(of: session.model.state) { _, state in
            if step == .clientPair, state == .paired { step = .success }
        }
    }

    private var roleChoice: some View {
        VStack(alignment: .leading, spacing: 20) {
            setupHeader("How will this Mac use Yorozu?", detail: "You can change this later in Settings.")
            roleButton(
                title: "Host Yorozu on this Mac",
                detail: "Run OpenClaw here and let your iPhone or other Macs connect.",
                systemImage: "macmini", role: .host
            )
            roleButton(
                title: "Connect to another Mac",
                detail: "Use Yorozu here while your host Mac does the work.",
                systemImage: "laptopcomputer.and.arrow.down", role: .client
            )
            Spacer()
        }
    }

    private func roleButton(title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String, role: MacRole) -> some View {
        Button {
            session.select(role)
            if role == .host {
                Sidecar.shared.newCode()
                step = .hostPair
            } else {
                step = .clientPair
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
    }

    private var hostPairing: some View {
        VStack(spacing: 10) {
            setupHeader("Connect your devices", detail: "Scan this code from Yorozu on an iPhone or client Mac.")
            PairingSheet(
                sidecar: .shared,
                existingDeviceIDs: Set(session.model.devices.filter { $0.via == .relay }.map(\.pub)),
                done: { step = .hostPermissions },
                autoDismiss: false,
                showsActions: false
            )
            Spacer()
            HStack {
                Button("Back") { session.clearRole(); step = .role }
                Spacer()
                Button("New code") { Sidecar.shared.newCode() }
                Button("Skip for now") { step = .hostPermissions }
                Button("Continue") { step = .hostPermissions }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var clientPairing: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupHeader("Connect to your host Mac", detail: "On the host Mac, open Settings › Devices › Pair Another Device, then paste its code here.")
            TextField("Paste pairing code", text: $pairingCode, axis: .vertical)
                .font(.system(.callout, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            Button("Connect") {
                do {
                    try session.pair(with: pairingCode)
                    pairingError = nil
                } catch {
                    pairingError = String(localized: "That pairing code is invalid or expired.")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if session.relay != nil && session.model.state != .paired && session.model.failure == nil {
                ProgressView("Connecting…")
            }
            if let pairingError {
                Text(pairingError).font(.caption).foregroundStyle(.red)
            } else if session.model.failure != nil {
                Text("Couldn’t connect. Generate a new pairing code and try again.")
                    .font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Button("Back") { session.clearRole(); step = .role }
        }
    }

    private var hostPermissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            setupHeader("Choose what Yorozu can do", detail: "Optional. Grant only capabilities you want; you can return anytime.")
            ScrollView { PermissionsView(showSetupButton: false, showsTitle: false) }
            HStack {
                Button("Back") { step = .hostPair }
                Spacer()
                Button("Finish", action: onFinish).buttonStyle(.borderedProminent)
            }
        }
    }

    private var success: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 58)).foregroundStyle(.green)
            Text("Connected").font(.title2.bold())
            Text("This Mac is ready to use Yorozu through your host Mac.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button("Open Yorozu", action: onFinish).buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    private func setupHeader(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
enum OnboardingWindow {
    static let completedKey = "onboardingCompleted"
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
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
        if MacChatSession.shared.role == nil { show() }
    }

    private static func finish() {
        UserDefaults.standard.set(true, forKey: completedKey)
        window?.close()
    }
}
