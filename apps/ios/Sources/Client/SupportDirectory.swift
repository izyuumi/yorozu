import Foundation

/// Where the client keeps its cache: the app's own container on iOS; on a Mac, which shares Application Support with
/// every app, a `client` folder in a folder named for the bundle id.
let clientSupportDirectory: URL = {
    #if os(macOS)
    URL.applicationSupportDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "to.yumi.yorozu.ios")/client", directoryHint: .isDirectory)
    #else
    URL.applicationSupportDirectory
    #endif
}()
