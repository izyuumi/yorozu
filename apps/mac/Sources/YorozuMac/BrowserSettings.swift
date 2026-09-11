import Foundation
import SwiftUI

/// Which browser the agent drives. The choice is one environment variable the sidecar
/// reads (`bundled`, or an absolute path to an executable); the runtime does the rest.
/// See docs/spec-v1.html section 4.
enum BrowserSettings {
    static let key = "YOROZU_BROWSER"

    /// `YOROZU_BROWSER=bundled`: Chrome for Testing, downloaded on first use.
    static let bundled = "bundled"

    struct Installed: Identifiable {
        let name: String
        /// The executable inside the bundle, which is what the runtime launches.
        let path: String
        var id: String { path }
    }

    /// Kept in step with KNOWN_BROWSERS in packages/runtime/src/tools/browser.ts.
    private static let known = [
        ("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ("Chromium", "/Applications/Chromium.app/Contents/MacOS/Chromium"),
        ("Brave", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
        ("Microsoft Edge", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        ("Arc", "/Applications/Arc.app/Contents/MacOS/Arc"),
    ]

    static func detected() -> [Installed] {
        known
            .filter { FileManager.default.isExecutableFile(atPath: $0.1) }
            .map { Installed(name: $0.0, path: $0.1) }
    }
}

struct BrowserView: View {
    @AppStorage(BrowserSettings.key) private var choice = BrowserSettings.bundled
    private let detected = BrowserSettings.detected()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Browser").font(.headline)
            Picker("Browser", selection: $choice) {
                Text("Bundled Chromium").tag(BrowserSettings.bundled)
                ForEach(detected) { browser in
                    Text(browser.name).tag(browser.path)
                }
            }
            .labelsHidden()
            Text("Runs in its own profile and never touches your tabs. Restart to apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
