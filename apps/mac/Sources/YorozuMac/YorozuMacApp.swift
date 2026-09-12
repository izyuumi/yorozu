import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import YorozuPermissions
import YorozuShared

/// The Node runtime sidecar, spawned by the app and killed with it. Its stdout is the
/// protocol: `STATE <state>` lines, and a `QR <string>` plus `PAIR <string>` line per pairing
/// payload. `MINT` back on its stdin asks for a fresh code.
@MainActor
final class Sidecar: ObservableObject {
    static let shared = Sidecar()

    @Published private(set) var state = "starting"
    /// Whether the runtime found a provider to use. Nil until it has looked. Kept apart from
    /// `state`, which every relay transition overwrites.
    @Published private(set) var providerSigned: Bool?
    @Published private(set) var qr: NSImage?
    /// The same payload the QR carries, for copying and pasting into the phone.
    @Published private(set) var pairingString: String?

    private let process = Process()
    private let input = Pipe()

    var isPaired: Bool { state == "paired" }

    func start() {
        let command = ProcessInfo.processInfo.environment["YOROZU_RUNTIME_CMD"]
            ?? RuntimeCommand.defaultCommand
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // Whatever the provider cards configured, including the Keychain API key.
        var environment = ProviderSettings.environment()
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
            return
        }
        Task { [weak self] in
            for try await line in output.fileHandleForReading.bytes.lines {
                self?.apply(line)
            }
            self?.state = "stopped"
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// Asks the sidecar to mint the next join token, which prints a fresh pairing payload.
    func newCode() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data("MINT\n".utf8))
    }

    private func apply(_ line: String) {
        if let name = line.dropping("STATE ") {
            switch name {
            case "provider-ok": providerSigned = true
            case "no-provider": providerSigned = false
            default: state = name
            }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Task { await Permission.logAll() }
            // Starts Sparkle here rather than when Settings is first opened: the whole point of
            // an automatic update is that nobody had to go looking for it.
            Updates.start()
            NeverSleep.shared.restoreFromDefaults()
            Sidecar.shared.start()
            // Connects to the sidecar's local socket once it is listening. Not tied to the
            // window: the chat has to keep up while the menu bar window is closed.
            LocalChat.start()
            OnboardingWindow.showIfFirstLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
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

    var body: some Scene {
        MenuBarExtra {
            ChatWindowView()
        } label: {
            Image(systemName: sidecar.isPaired ? "circle.fill" : "circle.dotted")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(sidecar: sidecar) }
    }
}
