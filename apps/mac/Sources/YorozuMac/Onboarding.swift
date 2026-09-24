import AppKit
import SwiftUI
import YorozuShared

/// First-run setup, and the place to finish it later. One window, two paths: a host goes
/// role → connect devices → permissions → done, a client goes role → connect → done. The
/// footer stays put on every step and only the middle scrolls, so Back and the primary action
/// never move under the pointer.
///
/// Nothing here decides whether an agent is ready. Pairing proves a device can reach this
/// Mac; which agent answers is set up on the host, and the copy says so rather than guessing.
struct OnboardingView: View {
    enum Step: Equatable { case role, hostPair, hostPermissions, hostDone, clientPair, clientDone }

    var onFinish: () -> Void
    var onOpen: () -> Void
    @State private var session = MacChatSession.shared
    @ObservedObject private var sidecar = Sidecar.shared
    @State private var step: Step
    @State private var pairingCode = ""
    @State private var pairingError: String?
    @State private var submittedCode: String?
    /// Set by ``PairingSheet`` when a device that was not in its baseline appears: the only
    /// evidence of a new pairing, and what turns "Skip for now" into "Continue".
    @State private var devicePaired = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onFinish: @escaping () -> Void, onOpen: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onOpen = onOpen
        let session = MacChatSession.shared
        _step = State(initialValue: Self.step(for: session.role, connected: session.model.state == .paired))
    }

    /// Where a role lands, on opening the window or on choosing it again. Only a client whose
    /// transport is `.paired` right now — the host's encrypted greeting, not merely the relay
    /// having joined it, which is all the saved `paired` flag proves — goes to its summary.
    /// Everything else is on the connect step with its progress showing.
    static func step(for role: MacRole?, connected: Bool) -> Step {
        switch role {
        case nil: .role
        case .host: .hostPair
        case .client: connected ? .clientDone : .clientPair
        }
    }

    private func step(for role: MacRole) -> Step {
        Self.step(for: role, connected: session.model.state == .paired)
    }

    var body: some View {
        Group {
            switch step {
            case .role: roleChoice
            case .hostPair: hostPairing
            case .hostPermissions: hostPermissions
            case .hostDone: hostDone
            case .clientPair: clientPairing
            case .clientDone: clientDone
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 600)
        .background(YorozuPalette.canvas)
        .yorozuTint()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step)
        // `initial`, because the handshake may have finished before this view existed.
        .onChange(of: session.model.state, initial: true) { _, state in
            if step == .clientPair, state == .paired { step = .clientDone }
        }
    }

    // MARK: Role

    private var roleChoice: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            YorozuMark(dimension: 44)
            VStack(spacing: 5) {
                Text("How will this Mac use Yorozu?").font(.title2.bold())
                Text("You can change this later in Settings › General.").foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                roleButton(
                    title: "Host Yorozu on this Mac",
                    detail: "Run the agents here. Your iPhone, iPad and other Macs connect to this one.",
                    systemImage: "macmini", role: .host
                )
                roleButton(
                    title: "Connect to another Mac",
                    detail: "Use Yorozu here while a host Mac you already set up does the work. Needs only its pairing code.",
                    systemImage: "laptopcomputer.and.arrow.down", role: .client
                )
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func roleButton(title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String, role: MacRole) -> some View {
        RoleChoiceButton(title: title, detail: detail, systemImage: systemImage) {
            // `select` is a no-op for the role already chosen, and keeps a stored client
            // pairing when switching — unlike `clearRole`, which this view never calls.
            session.select(role)
            // From the state the session is in now, not from the button: a client whose
            // handshake finished while this page was up goes straight to its summary.
            step = step(for: role)
        }
    }

    // MARK: Host

    private var hostPairing: some View {
        page(
            progress: (2, 4, "Connect"),
            title: "Connect your devices",
            detail: "Scan this code with Yorozu on an iPhone or iPad, or paste it into Yorozu on another Mac. You can also do this later from Settings › Devices."
        ) {
            ScrollView {
                PairingSheet(
                    sidecar: sidecar,
                    done: {},
                    autoDismiss: false,
                    onPaired: { devicePaired = true },
                    showsActions: false,
                    embedded: true
                )
                .frame(maxWidth: .infinity)
            }
        } footer: {
            Button("Back") { devicePaired = false; step = .role }
            Spacer()
            if devicePaired {
                Button("Continue") { step = .hostPermissions }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                // Codes come from the sidecar; none to replace while it is still starting.
                Button("New code") { sidecar.newCode() }
                    .disabled(sidecar.pairingString == nil)
                Button("Skip for now") { step = .hostPermissions }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var hostPermissions: some View {
        page(
            progress: (3, 4, "Permissions"),
            title: "Choose what Yorozu can do",
            detail: "All optional. Grant only what you want; each row re-checks itself and is always in Settings › Permissions."
        ) {
            PermissionsView(showSetupButton: false, scope: .onboarding)
                .padding(.horizontal, -24)
        } footer: {
            // Back rebuilds the sheet with a fresh baseline, so its earlier success is over.
            Button("Back") { devicePaired = false; step = .hostPair }
            Spacer()
            Text("Files and personal data: Settings › Permissions")
                .font(.caption).foregroundStyle(.secondary)
            Button("Finish") { step = .hostDone }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Paired devices other than this Mac's own local client, which is what "paired" means.
    private var pairedDeviceCount: Int {
        session.model.devices.filter { $0.via == .relay }.count
    }

    private var hostDone: some View {
        page(progress: (4, 4, "Done"), title: nil, detail: nil) {
            VStack(spacing: 16) {
                completion(
                    systemImage: "checkmark.circle.fill", tint: YorozuPalette.sage,
                    title: "This Mac is set up",
                    detail: "It hosts Yorozu. Your paired devices reach it through the relay."
                )
                summary {
                    summaryRow("Devices") {
                        Text(pairedDeviceCount == 0
                            ? "No devices paired yet"
                            : "^[\(pairedDeviceCount) device](inflect: true) paired")
                        Text("Pair more any time from Settings › Devices").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    summaryRow("Next") {
                        Text("Set up the agent you use on this Mac")
                        Text("OpenClaw for assistant chats. Claude Code or Codex for coding threads. A thread picks its agent when you start it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task { session.model.requestDevices() }
        } footer: {
            Button("Back") { step = .hostPermissions }
            Spacer()
            Button("Close", action: onFinish)
            Button("Open Yorozu", action: onOpen)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Client

    /// A stored pairing without the host's greeting yet, and nothing has gone wrong. That
    /// includes a host that is offline: the relay keeps trying, and the label says which.
    private var clientConnecting: Bool {
        session.relay != nil && session.model.state != .paired
            && session.model.failure == nil && session.failure == nil && pairingError == nil
    }

    private var clientProgressLabel: String {
        ClientConnectionStatus(
            state: session.model.state, ownerOnline: session.model.ownerOnline, failure: session.model.failure
        ).label
    }

    private var clientErrorMessage: String? {
        if let pairingError { return pairingError }
        if session.model.failure != nil || session.failure != nil {
            return String(localized: "Couldn’t connect. Retry, or paste a new code from the host Mac.")
        }
        return nil
    }

    private var clientPairing: some View {
        page(
            progress: (2, 3, "Connect"),
            title: "Connect to your host Mac",
            detail: "On the host, open Yorozu › Settings › Devices › Pair Another Device, then paste its code here. A tapped yorozu:// link works too."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Paste pairing code", text: $pairingCode, axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                if clientConnecting {
                    ProgressView(clientProgressLabel)
                    Text("The host Mac has to be online for the first handshake. This can take a few seconds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let clientErrorMessage {
                    Label {
                        Text(clientErrorMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    .font(.caption)
                }
            }
        } footer: {
            Button("Back") { step = .role }
            Spacer()
            // The connection that failed is kept; retrying it costs no new identity.
            if clientErrorMessage != nil, session.relay != nil {
                Button("Retry") { pairingError = nil; session.retryConnection() }
            }
            Button("Connect") {
                do {
                    try session.pair(with: pairingCode)
                    submittedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    pairingError = nil
                } catch {
                    pairingError = String(localized: "That pairing code is invalid or expired.")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            // Keep a pending one-time code from being submitted twice, while allowing a
            // replacement code when an earlier pairing cannot reach its host.
            .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (clientConnecting && submittedCode == pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private var clientDone: some View {
        let status = ClientConnectionStatus(
            state: session.model.state, ownerOnline: session.model.ownerOnline, failure: session.model.failure
        )
        let connected = status == .connected
        return page(progress: (3, 3, "Done"), title: nil, detail: nil) {
            VStack(spacing: 16) {
                completion(
                    systemImage: connected ? "checkmark.circle.fill" : "circle.dotted",
                    tint: connected ? YorozuPalette.sage : .secondary,
                    title: connected ? "Connected" : "Paired",
                    detail: "This Mac uses Yorozu through your host Mac. Agents run there."
                )
                summary {
                    summaryRow("Host Mac") {
                        Text(status.label)
                        if status == .hostOffline {
                            Text("Threads catch up when it is back. Yorozu keeps trying in the background.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    summaryRow("Next") {
                        Text("Open Yorozu and start a thread")
                        Text("Which agent answers is set up on the host Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Spacer()
            Button("Close", action: onFinish)
            Button("Open Yorozu", action: onOpen)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Layout

    /// A step: progress, a heading, the flexible middle, and a footer that stays where it is.
    private func page<Content: View, Footer: View>(
        progress: (Int, Int, LocalizedStringKey),
        title: LocalizedStringKey?,
        detail: LocalizedStringKey?,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIndicator(progress.0, of: progress.1, label: progress.2)
            if let title {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title2.bold())
                    if let detail {
                        Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack(spacing: 8) { footer() }
        }
    }

    private func stepIndicator(_ current: Int, of total: Int, label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { index in
                Circle()
                    .fill(index < current ? YorozuPalette.sage : index == current ? YorozuPalette.vermilion : YorozuPalette.stone)
                    .frame(width: 6, height: 6)
            }
            Text(label)
            Text("· \(current) of \(total)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current) of \(total)"))
    }

    private func completion(systemImage: String, tint: Color, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 56)).foregroundStyle(tint).accessibilityHidden(true)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    private func summary<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 10) { rows() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .yorozuPaperCard()
    }

    private func summaryRow<Value: View>(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) { value() }
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

private struct RoleChoiceButton: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            hovering ? YorozuPalette.stone : YorozuPalette.paper,
            in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
                .strokeBorder(YorozuPalette.rule.opacity(0.72), lineWidth: 0.75)
        }
        .onHover { hovering = $0 }
    }
}

@MainActor
enum OnboardingWindow {
    static let completedKey = "onboardingCompleted"
    /// Opens the chat window. Set by ``YorozuMacApp``: this window lives outside the SwiftUI
    /// scene graph, so the App is the only place with an `openWindow` that works.
    static var openChat: (() -> Void)?
    private static var window: NSWindow?

    /// Setup is complete once a role is chosen *and* the window was finished, so quitting
    /// halfway through brings it back next launch.
    static var isComplete: Bool {
        MacChatSession.shared.role != nil && UserDefaults.standard.bool(forKey: completedKey)
    }

    static func show() {
        let panel = window ?? makeWindow()
        // A window that was closed gets a fresh root view — its @State belonged to a setup
        // that ended — while one already on screen is only brought forward.
        if !panel.isVisible {
            panel.contentViewController = NSHostingController(rootView: OnboardingView(onFinish: finish, onOpen: open))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func showIfFirstLaunch() {
        if !isComplete { show() }
    }

    private static func makeWindow() -> NSWindow {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        panel.title = "Yorozu Setup"
        panel.contentMinSize = NSSize(width: 560, height: 600)
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        return panel
    }

    private static func finish() {
        UserDefaults.standard.set(true, forKey: completedKey)
        window?.close()
    }

    /// "Open Yorozu": finished, and straight into the chat.
    private static func open() {
        finish()
        NSApp.activate(ignoringOtherApps: true)
        openChat?()
    }
}
