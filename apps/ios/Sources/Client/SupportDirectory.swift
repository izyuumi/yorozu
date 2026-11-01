import Foundation

let clientSupportDirectory: URL = {
    #if os(macOS)
    URL.applicationSupportDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "to.yumi.yorozu.ios")/client", directoryHint: .isDirectory)
    #else
    URL.applicationSupportDirectory
    #endif
}()

/// Writes always use the new name; StoredNames resolves reads until migration completes.
func clientDirectory(_ name: String) -> URL {
    clientSupportDirectory.appending(path: name, directoryHint: .isDirectory)
}
