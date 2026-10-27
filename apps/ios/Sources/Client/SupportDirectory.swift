import Foundation

let clientSupportDirectory: URL = {
    #if os(macOS)
    URL.applicationSupportDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "to.yumi.yorozu.ios")/client", directoryHint: .isDirectory)
    #else
    URL.applicationSupportDirectory
    #endif
}()

/// The client's data directory `name`, moved once from its old name `<name>-v3`; the move goes in 0.11.
func clientDirectory(_ name: String) -> URL {
    let url = clientSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    if !FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.moveItem(at: clientSupportDirectory.appending(path: "\(name)-v3", directoryHint: .isDirectory), to: url)
    }
    return url
}
