import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import YorozuShared

/// The Node runtime sidecar, spawned by the app and killed with it. Its stdout is the
/// protocol: `STATE <state>` lines and one `QR <json>` line per pairing payload.
@MainActor
final class Sidecar: ObservableObject {
    static let shared = Sidecar()

    /// Dev default: `swift run` from `apps/mac` leaves the repo layout reachable.
    /// Override with YOROZU_RUNTIME_CMD; the DMG will point it at the bundled runtime.
    private static let defaultCommand = "node ../../packages/runtime/dist/serve.js"

    @Published private(set) var state = "starting"
    @Published private(set) var qr: NSImage?

    private let process = Process()

    var isPaired: Bool { state == "paired" }

    func start() {
        let command = ProcessInfo.processInfo.environment["YOROZU_RUNTIME_CMD"] ?? Self.defaultCommand
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
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

    private func apply(_ line: String) {
        if let name = line.dropping("STATE ") {
            state = name
        } else if let json = line.dropping("QR "), (try? QrPayload.decode(json)) != nil {
            qr = Self.qrImage(json)
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

struct PairingView: View {
    @ObservedObject var sidecar: Sidecar
    @ObservedObject private var neverSleep = NeverSleep.shared

    var body: some View {
        VStack(spacing: 12) {
            Text("Relay: \(sidecar.state)").font(.headline)
            if let qr = sidecar.qr {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("Pairing QR code")
                Text("Scan from the Yorozu iOS app.").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("Waiting for the runtime…").frame(height: 220)
            }
            Divider()
            Toggle("Never sleep", isOn: Binding(
                get: { neverSleep.isRunning },
                set: { $0 ? neverSleep.start() : neverSleep.stop() }
            ))
            Button("Set Up Permissions…") { OnboardingWindow.show() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 260)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Permission.logAll()
            NeverSleep.shared.restoreFromDefaults()
            Sidecar.shared.start()
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
            PairingView(sidecar: sidecar)
        } label: {
            Image(systemName: sidecar.isPaired ? "circle.fill" : "circle.dotted")
        }
        .menuBarExtraStyle(.window)
    }
}
