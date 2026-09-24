import Foundation

/// Where this package's processed resources (the provider marks) live at run time.
///
/// SwiftPM writes a `Bundle.module` accessor for every target with resources, but the one a
/// plain `swift build` writes looks in exactly one place: `YorozuShared_YorozuShared.bundle`
/// beside `Bundle.main.bundleURL`, the root of the .app. codesign refuses to seal an app with
/// anything but `Contents` at its root, so scripts/build-mac.sh can only put the bundle where
/// every other resource goes, `Contents/Resources`, and the generated accessor traps on the
/// first mark it is asked to draw. Xcode's accessor (the iOS app) already looks under
/// `resourceURL`; this one does the same on both platforms and only falls back to `.module`
/// where that is known to succeed: `swift test` and Xcode builds.
enum ResourceBundle {
    static let name = "YorozuShared_YorozuShared.bundle"

    /// The directories the bundle may sit in, most to least likely. Pure so a test can pin the
    /// order without an app around it.
    static func candidates(resourceURL: URL?, bundleURL: URL) -> [URL] {
        var urls: [URL] = []
        if let resourceURL {
            urls.append(resourceURL.appendingPathComponent(name))
        }
        let atRoot = bundleURL.appendingPathComponent(name)
        if !urls.contains(atRoot) {
            urls.append(atRoot)
        }
        return urls
    }

    static let shared: Bundle = {
        let main = Bundle.main
        for url in candidates(resourceURL: main.resourceURL, bundleURL: main.bundleURL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let bundle = Bundle(url: url)
            else { continue }
            return bundle
        }
        return .module
    }()
}
