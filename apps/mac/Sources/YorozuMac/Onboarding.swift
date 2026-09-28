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
                Text("How will this Mac use Yorozu?").font(.scaled(.title2).bold())
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
        .padding(Self.inset)
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
            detail: "All optional. Grant only what you want; each row re-checks itself and stays in Settings.",
            edgeToEdge: true
        ) {
            PermissionsView(scope: .onboarding)
        } footer: {
            // Back rebuilds the sheet with a fresh baseline, so its earlier success is over.
            Button("Back") { devicePaired = false; step = .hostPair }
            Spacer()
            Button("Continue") { step = .hostDone }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Paired devices other than this Mac's own local client, which is what "paired" means.
    private var pairedDeviceCount: Int {
        session.model.devices.filter { $0.via == .relay }.count
    }
    /// The list revision when the summary asked, so an old or empty list is not read as the answer.
    @State private var devicesAskedAt: Int?

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
                        if devicesAskedAt.map({ session.model.deviceListRevision == $0 }) ?? true {
                            Text("Checking…")
                        } else {
                            Text(pairedDeviceCount == 0
                                ? "No devices paired yet"
                                : "^[\(pairedDeviceCount) device](inflect: true) paired")
                        }
                        Text("Pair more any time from Settings › Devices").font(.scaled(.caption)).foregroundStyle(.secondary)
                    }
                    Divider()
                    summaryRow("Agents") {
                        Text("A thread picks its agent when you start it. Set up the ones you’ll use.")
                            .font(.scaled(.caption)).foregroundStyle(.secondary)
                        AgentReadinessList(model: session.model)
                    }
                }
            }
            .task {
                devicesAskedAt = session.model.deviceListRevision
                session.model.requestDevices()
            }
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
    private var clientFailure: String? {
        session.failure ?? session.hostFailures[session.hosts.preferredHostID ?? ""] ?? session.model.failure
    }

    private var clientConnecting: Bool {
        session.relay != nil && session.model.state != .paired
            && clientFailure == nil && pairingError == nil
    }

    private var clientProgressLabel: String {
        ClientConnectionStatus(
            state: session.model.state, ownerOnline: session.model.ownerOnline, failure: clientFailure
        ).label
    }

    private var clientErrorMessage: String? {
        if let pairingError { return pairingError }
        if clientFailure != nil {
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
                        .font(.scaled(.caption)).foregroundStyle(.secondary)
                }
                if let clientErrorMessage {
                    Label {
                        Text(clientErrorMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    .font(.scaled(.caption))
                }
            }
        } footer: {
            Button("Back") { step = .role }
            Spacer()
            // The connection that failed is kept; retrying it costs no new identity.
            if clientErrorMessage != nil, let hostID = session.hosts.preferredHostID {
                Button("Retry") { pairingError = nil; session.retryConnection(hostID) }
            }
            Button("Connect") {
                do {
                    try session.pair(with: pairingCode)
                    submittedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    pairingError = nil
                } catch MacChatSession.PairingError.alreadyConnected {
                    // A replacement code for this host needs the same explicit repair
                    // consent as Settings and links; another host must never be replaced.
                    if let payload = try? QrPayload.decode(pairingCode), let code = try? payload.encoded(),
                       let url = URL(string: code) {
                        pairingError = nil
                        session.handlePairingLink(url)
                    }
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
        let status = ClientConnectionStatus(session.model, failure: session.model.failure)
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
                                .font(.scaled(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    summaryRow("Next") {
                        Text("Open Yorozu and start a thread")
                        Text("Which agent answers is set up on the host Mac.")
                            .font(.scaled(.caption)).foregroundStyle(.secondary)
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
    /// The window's margin. A page applies it itself, so an `edgeToEdge` grouped Form can span
    /// the width and inset its own sections the way Settings does.
    private static let inset: CGFloat = 24

    private func page<Content: View, Footer: View>(
        progress: (Int, Int, LocalizedStringKey),
        title: LocalizedStringKey?,
        detail: LocalizedStringKey?,
        edgeToEdge: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                stepIndicator(progress.0, of: progress.1, label: progress.2)
                if let title {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.scaled(.title2).bold())
                        if let detail {
                            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding([.horizontal, .top], Self.inset)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, edgeToEdge ? 0 : Self.inset)
            HStack(spacing: 8) { footer() }
                .padding([.horizontal, .bottom], Self.inset)
        }
    }

    /// The progress dots' diameter: this component's own geometry, not a layout guess.
    private static let stepDot: CGFloat = 6

    private func stepIndicator(_ current: Int, of total: Int, label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { index in
                Circle()
                    .fill(index < current ? YorozuPalette.sage : index == current ? YorozuPalette.vermilion : YorozuPalette.stone)
                    .frame(width: Self.stepDot, height: Self.stepDot)
            }
            Text(label)
            Text("· \(current) of \(total)")
        }
        .font(.scaled(.caption2))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(label)), step \(current) of \(total)"))
    }

    private func completion(systemImage: String, tint: Color, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 56)).foregroundStyle(tint).accessibilityHidden(true)
            Text(title).font(.scaled(.title2).bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    /// A grid, so the label column is as wide as its widest label at any text size or language.
    /// A row that is not a ``summaryRow`` — a divider — spans both columns.
    private func summary<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) { rows() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .yorozuPaperCard()
    }

    private func summaryRow<Value: View>(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) { value() }
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.scaled(.callout))
    }
}

private struct RoleChoiceButton: View {
    /// One column for every card's symbol, so the titles line up whatever the symbol's width.
    private static let iconColumn: CGFloat = 32

    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.scaled(.title2)).frame(width: Self.iconColumn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.scaled(.headline))
                    Text(detail).font(.scaled(.caption)).foregroundStyle(.secondary)
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
