import AppKit
import CoreImage.CIFilterBuiltins
import CoreServices
import SwiftUI
import YorozuKeepalive
import YorozuPermissions
import YorozuShared

/// The Node runtime sidecar, spawned by the app and killed with it. Its stdout is the
/// protocol: `STATE <state>` lines, and a `QR <string>` plus `PAIR <string>` line per pairing
/// payload. `MINT` back on its stdin asks for a fresh code.
///
/// It is also restarted when it dies. A sidecar that exits takes the relay, the phone and
/// every tool with it while the app carries on looking perfectly alive in the menu bar, which
/// is the quietest way for this Mac to stop working.
@MainActor
final class Sidecar: ObservableObject {
    static let shared = Sidecar()

    @Published private(set) var state = "starting"
    @Published private(set) var qr: NSImage?
    /// The same payload the QR carries, for copying and pasting into the phone.
    @Published private(set) var pairingString: String?

    private var process: Process?
    private var input = Pipe()
    /// Consecutive failed starts, which is what the delay between them is derived from.
    private var restarts = 0
    /// Invalidates stdout/end callbacks from a process stopped during a live role switch.
    private var generation = 0
    /// Set by ``stop``, so quitting is not mistaken for a crash worth restarting.
    private var stopping = false

    var isPaired: Bool { state == "paired" }

    func start() {
        generation += 1
        stopping = false
        spawn(generation: generation)
    }

    /// One thing to run: an executable and its arguments, handed to `Process` as they are.
    /// There is no shell in between, so a path with a space in it — an .app in "Application
    /// Support", a checkout under a name with one — is one argument and nothing else.
    struct Launch: Equatable {
        var executable: URL
        var arguments: [String]
    }

    /// The runtime this build runs: the node and `serve.js` `scripts/build-mac.sh` bundled, else
    /// the dev checkout this source file sits in, which is what `swift run` from `apps/mac`
    /// leaves in place. `YOROZU_RUNTIME_CMD` overrides both, split into words here rather than
    /// given to `/bin/sh`. Nil when nothing runnable was found, which is logged and retried.
    static func launch(environment: [String: String]) -> Launch? {
        // An override set to nothing is no override: it falls through to the defaults rather
        // than spinning the restart loop on an empty command.
        if let command = environment["YOROZU_RUNTIME_CMD"], !shellWords(command).isEmpty {
            return launch(words: shellWords(command), environment: environment)
        }
        return bundledLaunch() ?? devLaunch(environment: environment)
    }

    private static func bundledLaunch() -> Launch? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let node = resources.appendingPathComponent("node")
        let serve = resources.appendingPathComponent("runtime/dist/serve.js")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.isReadableFile(atPath: serve.path)
        else { return nil }
        return Launch(executable: node, arguments: [serve.path])
    }

    /// `packages/runtime/dist/serve.js` relative to this file, not to the working directory:
    /// the app is launched from wherever Finder, `open` or the watchdog happened to be.
    private static func devLaunch(environment: [String: String]) -> Launch? {
        let root = URL(fileURLWithPath: #filePath)  // apps/mac/Sources/YorozuMac/YorozuMacApp.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let serve = root.appending(path: "packages/runtime/dist/serve.js")
        guard FileManager.default.isReadableFile(atPath: serve.path),
              let node = executable(named: "node", environment: environment)
        else { return nil }
        return Launch(executable: node, arguments: [serve.path])
    }

    private static func launch(words: [String], environment: [String: String]) -> Launch? {
        guard let first = words.first, !first.isEmpty else { return nil }
        let executable = first.contains("/")
            ? URL(fileURLWithPath: first)
            : executable(named: first, environment: environment)
        guard let executable else { return nil }
        return Launch(executable: executable, arguments: Array(words.dropFirst()))
    }

    /// Looks a bare command name up on the app's own `PATH`, then where Homebrew and a
    /// package install put node: an app opened from Finder has `/usr/bin:/bin` and little else.
    private static func executable(named name: String, environment: [String: String]) -> URL? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = path + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.lazy
            .map { URL(fileURLWithPath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The words of a command as `sh` would split them, for the subset `YOROZU_RUNTIME_CMD` has
    /// ever used: whitespace separates, single and double quotes group, a backslash escapes
    /// the next character outside single quotes. Nothing expands: there is no shell to expand
    /// it, which is the point.
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                current.append(character); escaped = false; continue
            }
            if let open = quote {
                if character == open { quote = nil }
                else if character == "\\", open == "\"" { escaped = true }
                else { current.append(character) }
                continue
            }
            switch character {
            case "\'", "\"": quote = character; inWord = true
            case "\\": escaped = true; inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(character); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Where the sidecar keeps its keys, threads and socket: what `YOROZU_STATE_DIR` names, or
    /// the runtime's own default under Application Support — the same choice
    /// `LocalSocketTransport.defaultPath()` makes, so the app dials the socket it creates.
    static var stateDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["YOROZU_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return URL.applicationSupportDirectory.appending(path: "Yorozu")
    }

    /// The variables the sidecar is given, out of everything the app was launched with. The
    /// runtime needs its own `YOROZU_*`, the provider keys a dev run exports, and enough of
    /// the login environment to find node and a home directory; it gets nothing else, because
    /// the app's environment is whatever launched it — a shell with secrets exported, a
    /// LaunchAgent, a screenshot script — and the runtime spawns agents that run commands.
    ///
    /// `LC_*` is a prefix because the locale is a family of variables; the others are exact.
    static let passedEnvironment: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG", "USER", "SHELL"]
    static let passedEnvironmentPrefixes = ["LC_", "YOROZU_", "CLAUDE_", "ANTHROPIC_", "CODEX_", "OPENAI_"]

    static func sidecarEnvironment(from environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            passedEnvironment.contains(name) || passedEnvironmentPrefixes.contains { name.hasPrefix($0) }
        }
    }

    /// What the runtime's `/bin/sh` reads back as exactly `path`, however it is spelt: one
    /// single-quoted word, with any single quote inside it closed, escaped and reopened.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func spawn(generation: Int) {
        let inherited = ProcessInfo.processInfo.environment
        // Looked up in the full environment — `PATH` is passed through anyway — and then run
        // with only the allowlisted part of it.
        guard let launch = Self.launch(environment: inherited) else {
            state = "failed: no runtime found"
            Log.write("sidecar: no bundled runtime, dev checkout or YOROZU_RUNTIME_CMD to run")
            scheduleRestart(ranFor: 0, generation: generation)
            return
        }
        let output = Pipe()
        let process = Process()
        input = Pipe()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        // The sidecar's working directory is its state directory rather than whatever the app
        // inherited — `/` when opened from Finder — so a relative path it ever resolves lands
        // among its own files. Created first: `run()` refuses a directory that is not there.
        let stateDirectory = Self.stateDirectory
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        process.currentDirectoryURL = stateDirectory
        var environment = Self.sidecarEnvironment(from: inherited)
        if environment["YOROZU_STATE_DIR"] == nil { environment["YOROZU_STATE_DIR"] = stateDirectory.path }
        // The relay chosen in General; an explicit YOROZU_RELAY_URL in the app's own
        // environment still wins, for dev runs.
        if environment[RelaySettings.key] == nil { environment[RelaySettings.key] = RelaySettings.url }
        // The native tool host, if this build is bundled. Quoted because the *runtime* runs
        // this one through /bin/sh — see `nativeCommand` in packages/runtime — and an .app can
        // sit in a path with spaces in it.
        if environment["YOROZU_NATIVE_CMD"] == nil,
           let helper = Bundle.main.url(forAuxiliaryExecutable: "yorozu-native") {
            environment["YOROZU_NATIVE_CMD"] = Self.shellQuoted(helper.path)
        }
        environment["YOROZU_APP_VERSION"] = Bundle.main.infoDictionary?["YorozuVersionLabel"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
        process.environment = environment
        process.standardOutput = output
        process.standardInput = input
        do {
            try process.run()
        } catch {
            state = "failed: \(error.localizedDescription)"
            Log.write("sidecar: could not start \(launch.executable.path) — \(error.localizedDescription)")
            scheduleRestart(ranFor: 0, generation: generation)
            return
        }
        self.process = process
        Log.write("sidecar: started (pid \(process.processIdentifier))")
        let started = Date()
        Task { [weak self] in
            // The stream ending — cleanly or by throwing — is the sidecar being gone, and
            // both go to the same place. Anything else would drop a crash on the floor.
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard self?.generation == generation else { return }
                    self?.apply(line)
                }
            } catch {}
            self?.ended(ranFor: Date().timeIntervalSince(started), generation: generation)
        }
    }

    func stop() {
        generation += 1
        stopping = true
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    private func ended(ranFor seconds: TimeInterval, generation: Int) {
        guard generation == self.generation else { return }
        state = "stopped"
        process = nil
        guard !stopping else { return }
        Log.write("sidecar: exited after \(Int(seconds))s")
        scheduleRestart(ranFor: seconds, generation: generation)
    }

    /// Doubling from a second up to a minute, so a sidecar that cannot start does not spin,
    /// and one that dies once is back before the phone notices.
    ///
    /// The count resets after a run that lasted a minute: that was a working sidecar that
    /// later died, not the same failure over and over, and it deserves a fast retry.
    private func scheduleRestart(ranFor seconds: TimeInterval, generation: Int) {
        if seconds >= 60 { restarts = 0 }
        let delay = min(pow(2, Double(restarts)), 60)
        restarts += 1
        state = "restarting in \(Int(delay))s"
        Log.write("sidecar: restarting in \(Int(delay))s (attempt \(restarts))")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopping, self.generation == generation else { return }
            self.spawn(generation: generation)
        }
    }

    /// Asks the sidecar to mint the next join token, which prints a fresh pairing payload.
    func newCode() {
        qr = nil
        pairingString = nil
        guard process?.isRunning == true else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data("MINT\n".utf8))
    }

    private func apply(_ line: String) {
        if let name = line.dropping("STATE ") {
            state = name
        } else if let text = line.dropping("QR "), (try? QrPayload.decode(text)) != nil {
            qr = Self.qrImage(text)
        } else if let text = line.dropping("PAIR "), (try? QrPayload.decode(text)) != nil {
            pairingString = text
        }
    }

    private static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // The generator emits one pixel per module; scale up before rasterising.
        guard let image = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: image)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}

private extension String {
    /// The remainder after `prefix`, or nil when the line is not that kind.
    func dropping(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var explicitQuitRequested = false

    @MainActor static func closeWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            window.performClose(nil)
        }
    }

    @MainActor func requestQuit() {
        explicitQuitRequested = true
        NSApp.terminate(nil)
    }

    /// Yorozu is a menu-bar agent. Closing chat or Settings only hides UI; relay, runtime,
    /// updates, and phone connectivity keep running until the user explicitly chooses Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if HostWindowMode.active && !Updates.installing {
                // A key equivalent can still reach AppKit directly from a Settings scene.
                // Intercept only the actual ⌘Q event; OS logout and Sparkle termination pass.
                if let event = NSApp.currentEvent, event.type == .keyDown,
                   event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
                    Self.closeWindows()
                    return .terminateCancel
                }
                if explicitQuitRequested && !MacChatSession.shared.model.generating.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Tasks are still running"
                    alert.informativeText = "Quitting Yorozu stops this Mac's active tasks and disconnects paired devices."
                    alert.addButton(withTitle: "Keep Yorozu Running")
                    alert.addButton(withTitle: "Quit Yorozu")
                    if alert.runModal() == .alertFirstButtonReturn {
                        explicitQuitRequested = false
                        return .terminateCancel
                    }
                }
            }
            if Updates.pending.status.phase != .none && !Updates.installing && !HostWindowMode.active {
                let alert = NSAlert()
                alert.messageText = "Update is waiting"
                alert.informativeText = "Yorozu will restart after this Mac’s agents finish, any postponement expires, and the 10-second countdown completes."
                alert.addButton(withTitle: "Keep Yorozu Running")
                alert.runModal()
                explicitQuitRequested = false
                return .terminateCancel
            }
            guard Updates.installing else { return .terminateNow }
            do {
                try MacChatSession.shared.saveForRestart()
                return .terminateNow
            } catch {
                Updates.pending.retryAfterSnapshotFailure(error)
                return .terminateCancel
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let event = NSAppleEventManager.shared().currentAppleEvent
            let loginLaunch = event?.eventID == kAEOpenApplication
                && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            let watchdogLaunch = ProcessInfo.processInfo.arguments.contains("-yorozuWatchdogLaunch")
            let updateRelaunch = UserDefaults.standard.bool(forKey: HostWindowMode.updateRelaunchKey)
            UserDefaults.standard.removeObject(forKey: HostWindowMode.updateRelaunchKey)
            if HostWindowMode.active && event?.eventID == kAEOpenApplication
                && !loginLaunch && !watchdogLaunch && !updateRelaunch {
                HostWindowMode.pendingExplicitOpen = true
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
            Log.write("launch: build \(version) at \(Bundle.main.bundlePath)")
            // Debug builds only: the screenshot scripts and the keyboard UI tests run a debug
            // bundle (`scripts/dev-bundle.sh` defaults to it), and a shipped build should not
            // change what it does for an argument or a variable whoever launched it can set.
            #if DEBUG
            let ephemeral = ProcessInfo.processInfo.arguments.contains("-yorozuShowcase")
                || ProcessInfo.processInfo.environment["YOROZU_EPHEMERAL_RUN"] == "1"
            #else
            let ephemeral = false
            #endif
            if ephemeral {
                // Screenshot/showcase bundles must never become login items or supervise
                // themselves. They are deliberately disposable and may live under /tmp.
                Watchdog.remove()
                LoginItem.set(false)
            } else {
                // Whatever the last quit left behind, this Mac is up now and wants supervising.
                Watchdog.clearPause()
                // Re-registered rather than only written once: an update moves the bundle, and an
                // agent pointing at the old path supervises nothing.
                if Watchdog.isEnabled { Watchdog.install() }
                LoginItem.enableByDefaultOnce()
            }
            Task { await Permission.logAll() }
            // Starts Sparkle here rather than when Settings is first opened: the whole point of
            // an automatic update is that nobody had to go looking for it.
            Updates.start()
            if MacChatSession.shared.role == .host { NeverSleep.shared.restoreFromDefaults() }
            LocalNotifications.shared.start()
            MacChatSession.shared.start()
            #if DEBUG
            // Test harness only, and inert without a `-yorozuShowcase` argument. After
            // `LocalChat.start`, whose thread hook it chains onto.
            Showcase.attach(to: MacChatSession.shared.model)
            #endif
            // First-launch setup is shown from the `MenuBarExtra` label's task, once the
            // window has a way into the chat — see ``OnboardingWindow/openChat``.
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard HostWindowMode.active else { return true }
            HostWindowMode.requestQuickChat()
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Only a menu quit removes supervision in background-only mode. Sparkle's
            // relaunch and session shutdown keep it for recovery at the next login.
            if Updates.installing {
                Log.write("quit: installing an update, watchdog left running")
            } else if explicitQuitRequested || !HostWindowMode.active {
                Watchdog.remove()
            } else {
                Log.write("quit: system termination, watchdog left running")
            }
            Sidecar.shared.stop()
            // Quitting is not the user opting out: keep the preference for the next launch.
            NeverSleep.shared.stop(persist: false)
        }
    }
}

@main
struct YorozuMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var sidecar = Sidecar.shared
    @State private var session = MacChatSession.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    /// Whether setup was finished, so the menu can offer the way back to it until it was.
    @AppStorage(OnboardingWindow.completedKey) private var onboardingCompleted = false
    @AppStorage(HostWindowMode.key) private var backgroundOnlyHost = false
    @AppStorage(MacNotificationPreference.attentionIndicator) private var attentionIndicator = true

    /// The chat window's id, so the status item can ask for it by name.
    static let chatWindow = "chat"
    static let quickChatWindow = "quick-chat"

    private func openQuickChat() {
        openWindow(id: Self.quickChatWindow)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // The chat is a real window. It used to be the menu bar item's own popover, which cost
        // it a toolbar, a resizable frame, working sheets and share pickers, and any menu bar
        // at all to hang ⌘N, ⌘F and Stop off — see ``ChatWindowView``.
        Window("Yorozu", id: Self.chatWindow) {
            Group {
                if HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost) {
                    Color.clear.task { dismissWindow(id: Self.chatWindow) }
                } else {
                    ChatWindowView()
                }
            }
                // A `yorozu://pair` link, from Messages or a browser. Asked about before it
                // replaces anything — see ``MacChatSession/handlePairingLink(_:)``. Other hosts
                // are the phone's, and mean nothing here.
                .onOpenURL { url in MacChatSession.shared.handlePairingLink(url) }
                // The same road for a code tapped inside a chat bubble.
                .environment(\.onPairingLink) { MacChatSession.shared.handlePairingLink($0) }
                .onAppear { WindowPresence.opened() }
                .onDisappear {
                    WindowPresence.closed()
                    // Shutting the chat stops it talking. The chat view cannot do this itself
                    // on the Mac — see the note on `onChange(of:)` in ``ChatView``.
                    Speaker.shared.stop()
                }
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            ChatMenus()
            HostQuitCommands(backgroundOnly: HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost))
        }
        .handlesExternalEvents(matching: ["pair"])

        Window("Quick Chat", id: Self.quickChatWindow) {
            Group {
                if session.role == .host {
                    QuickChatView()
                } else {
                    Color.clear.task { dismissWindow(id: Self.quickChatWindow) }
                }
            }
            .onOpenURL { MacChatSession.shared.handlePairingLink($0) }
            .environment(\.onPairingLink) { MacChatSession.shared.handlePairingLink($0) }
            .onDisappear { Speaker.shared.stop() }
        }
        .defaultSize(width: QuickChatView.initialWidth, height: QuickChatView.initialHeight)
        .commands { HostQuitCommands(backgroundOnly: HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost)) }

        // The status item is now the way to that window rather than the place the chat lives.
        // A menu rather than a panel, because everything in it is one click that goes somewhere.
        MenuBarExtra {
            if HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost) {
                Button("Quick Chat") { openQuickChat() }
                Button("New Chat") {
                    QuickChatRouter.shared.target = nil
                    let id = session.model.newDraft().id
                    UserDefaults.standard.set(id, forKey: "quickChatThreadID")
                    openQuickChat()
                }
            }
            if !HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost) {
                Button("Open Yorozu") { openWindow(id: Self.chatWindow) }
                    .keyboardShortcut("o")
            }
            if HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost) {
                let attention = MacAttentionItem.pending(in: session.model)
                if !attention.isEmpty || Updates.pending.failure != nil {
                    Section("Needs Attention") {
                        ForEach(attention) { item in
                            Button(item.label) {
                                HostWindowMode.routeQuickChat(threadID: item.threadID,
                                    eventID: item.eventID, kind: item.kind)
                            }
                        }
                        if Updates.pending.failure != nil {
                            Button("Update needs attention") {
                                SettingsPaneRouter.shared.selection = "updates"
                                openSettings()
                            }
                        }
                    }
                }
            }
            if session.role == nil || !onboardingCompleted {
                Button("Finish Setup…") { OnboardingWindow.show() }
            }
            Divider()
            SettingsLink { Text("Settings…") }
            CheckForUpdatesButton()
            if HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost),
               let check = Updates.checkResult.message {
                Text(check).disabled(true)
            }
            if Updates.pending.status.phase != .none {
                Text(Updates.pending.status.label()).disabled(true)
                if Updates.pending.status.phase != .installing {
                    Button("Postpone update 1 hour") { Updates.pending.postpone() }
                }
            }
            if let failure = Updates.pending.failure { Text(failure).disabled(true) }
            Divider()
            // Not a control: the sidecar's own word for where the relay stands, which is the
            // one thing worth knowing without opening anything.
            Text(session.role == .host ? sidecar.state : "client").disabled(true)
            Divider()
            Button(HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost)
                ? "Quit Yorozu…" : "Quit Yorozu") {
                (NSApp.delegate as? AppDelegate)?.requestQuit()
            }
        } label: {
            Image(systemName: (session.role == .client ? session.hosts.sessions.contains { $0.model.canDeliver } : session.model.state == .paired) ? "circle.fill" : "circle.dotted")
                .overlay(alignment: .topTrailing) {
                    if HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost)
                        && attentionIndicator
                        && (!MacAttentionItem.pending(in: session.model).isEmpty || Updates.pending.failure != nil) {
                        HostAttentionIndicator()
                    }
                }
                .accessibilityLabel((session.role == .client ? session.hosts.sessions.contains { $0.model.canDeliver } : session.model.state == .paired) ? "Yorozu, connected" : "Yorozu, not connected")
                .task {
                    // The setup window's way into the chat: it is an NSWindow outside this
                    // scene graph, and this is the `openWindow` that works.
                    OnboardingWindow.openChat = {
                        if !HostWindowMode.active { openWindow(id: Self.chatWindow) }
                    }
                    HostWindowMode.openQuickChat = { openQuickChat() }
                    if HostWindowMode.pendingExplicitOpen {
                        HostWindowMode.pendingExplicitOpen = false
                        if QuickChatRouter.shared.target != nil { openQuickChat() }
                        else { HostWindowMode.requestQuickChat() }
                    }
                    OnboardingWindow.showIfFirstLaunch()
                    if UserDefaults.standard.bool(forKey: "restoreChatAfterUpdate") {
                        UserDefaults.standard.removeObject(forKey: "restoreChatAfterUpdate")
                        if !HostWindowMode.active { openWindow(id: Self.chatWindow) }
                    }
                }
        }

        Settings { SettingsView(sidecar: sidecar) }
            .commands { HostQuitCommands(backgroundOnly: HostWindowMode.active(role: session.role, enabled: backgroundOnlyHost)) }
    }
}

private struct HostAttentionIndicator: View {
    private static let diameter: CGFloat = 6

    var body: some View {
        Circle().fill(YorozuPalette.vermilion)
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
    }
}
