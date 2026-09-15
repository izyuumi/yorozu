import AppKit
import CoreImage.CIFilterBuiltins
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
    /// Set by ``stop``, so quitting is not mistaken for a crash worth restarting.
    private var stopping = false

    var isPaired: Bool { state == "paired" }

    func start() {
        stopping = false
        spawn()
    }

    private func spawn() {
        let command = ProcessInfo.processInfo.environment["YOROZU_RUNTIME_CMD"]
            ?? RuntimeCommand.defaultCommand
        let output = Pipe()
        let process = Process()
        input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        // The native tool host, if this build is bundled: quoted because the runtime runs the
        // command through /bin/sh, and an .app can sit in a path with spaces in it.
        if environment["YOROZU_NATIVE_CMD"] == nil,
           let helper = Bundle.main.url(forAuxiliaryExecutable: "yorozu-native") {
            environment["YOROZU_NATIVE_CMD"] = "'\(helper.path)'"
        }
        process.environment = environment
        process.standardOutput = output
        process.standardInput = input
        do {
            try process.run()
        } catch {
            state = "failed: \(error.localizedDescription)"
            Log.write("sidecar: could not start — \(error.localizedDescription)")
            scheduleRestart(ranFor: 0)
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
                    self?.apply(line)
                }
            } catch {}
            self?.ended(ranFor: Date().timeIntervalSince(started))
        }
    }

    func stop() {
        stopping = true
        if process?.isRunning == true { process?.terminate() }
    }

    private func ended(ranFor seconds: TimeInterval) {
        state = "stopped"
        process = nil
        guard !stopping else { return }
        Log.write("sidecar: exited after \(Int(seconds))s")
        scheduleRestart(ranFor: seconds)
    }

    /// Doubling from a second up to a minute, so a sidecar that cannot start does not spin,
    /// and one that dies once is back before the phone notices.
    ///
    /// The count resets after a run that lasted a minute: that was a working sidecar that
    /// later died, not the same failure over and over, and it deserves a fast retry.
    private func scheduleRestart(ranFor seconds: TimeInterval) {
        if seconds >= 60 { restarts = 0 }
        let delay = min(pow(2, Double(restarts)), 60)
        restarts += 1
        state = "restarting in \(Int(delay))s"
        Log.write("sidecar: restarting in \(Int(delay))s (attempt \(restarts))")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopping else { return }
            self.spawn()
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
    /// Yorozu is a menu-bar agent. Closing chat or Settings only hides UI; relay, runtime,
    /// updates, and phone connectivity keep running until the user explicitly chooses Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
            Log.write("launch: build \(version) at \(Bundle.main.bundlePath)")
            // Whatever the last quit left behind, this Mac is up now and wants supervising.
            Watchdog.clearPause()
            // Re-registered rather than only written once: an update moves the bundle, and an
            // agent pointing at the old path supervises nothing.
            if Watchdog.isEnabled { Watchdog.install() }
            LoginItem.enableByDefaultOnce()
            Task { await Permission.logAll() }
            // Starts Sparkle here rather than when Settings is first opened: the whole point of
            // an automatic update is that nobody had to go looking for it.
            Updates.start()
            NeverSleep.shared.restoreFromDefaults()
            Sidecar.shared.start()
            // Connects to the sidecar's local socket once it is listening. Not tied to the
            // window: the chat has to keep up while the chat window is closed.
            LocalChat.start()
            // Test harness only, and inert without a `-yorozuShowcase` argument. After
            // `LocalChat.start`, whose thread hook it chains onto.
            Showcase.attach(to: LocalChat.model)
            OnboardingWindow.showIfFirstLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // A quit the user asked for has to stick, or the watchdog undoes it within the
            // minute. A crash never gets here, writes no pause, and is relaunched — which is
            // the whole distinction the pause file exists to draw.
            //
            // Sparkle's relaunch is not a quit: it is about to start the new build itself, and
            // if that fails the watchdog is exactly who should notice.
            if Updates.installing {
                Log.write("quit: installing an update, watchdog left running")
            } else {
                Watchdog.pause()
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
    @Environment(\.openWindow) private var openWindow

    /// The chat window's id, so the status item can ask for it by name.
    static let chatWindow = "chat"

    var body: some Scene {
        // The chat is a real window. It used to be the menu bar item's own popover, which cost
        // it a toolbar, a resizable frame, working sheets and share pickers, and any menu bar
        // at all to hang ⌘N, ⌘F and Stop off — see ``ChatWindowView``.
        Window("Yorozu", id: Self.chatWindow) {
            ChatWindowView()
                .onAppear { WindowPresence.opened() }
                .onDisappear {
                    WindowPresence.closed()
                    // Shutting the chat stops it talking. The chat view cannot do this itself
                    // on the Mac — see the note on `onChange(of:)` in ``ChatView``.
                    Speaker.shared.stop()
                }
        }
        .defaultSize(width: 860, height: 560)
        .commands { ChatMenus() }

        // The status item is now the way to that window rather than the place the chat lives.
        // A menu rather than a panel, because everything in it is one click that goes somewhere.
        MenuBarExtra {
            Button("Open Yorozu") { openWindow(id: Self.chatWindow) }
                .keyboardShortcut("o")
            Divider()
            SettingsLink { Text("Settings…") }
            CheckForUpdatesButton()
            Divider()
            // Not a control: the sidecar's own word for where the relay stands, which is the
            // one thing worth knowing without opening anything.
            Text(sidecar.state).disabled(true)
            Divider()
            Button("Quit Yorozu") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: sidecar.isPaired ? "circle.fill" : "circle.dotted")
        }

        Settings { SettingsView(sidecar: sidecar) }
    }
}
