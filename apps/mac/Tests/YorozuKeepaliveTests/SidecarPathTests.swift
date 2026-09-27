import Foundation
import Testing

@testable import YorozuMac

/// An app opened from Finder has launchd's `PATH`, so the sidecar's comes from the login shell.
@MainActor @Test func sidecarSearchPathPutsLoginShellEntriesAheadOfLaunchdDefaults() {
    #expect(Sidecar.searchPath(login: "/opt/homebrew/bin:/usr/bin:/bin", inherited: "/usr/bin:/bin:/usr/sbin:/sbin")
        == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    // Launched from a shell that already has every login entry: the order it chose stands.
    #expect(Sidecar.searchPath(login: "/opt/homebrew/bin:/usr/bin", inherited: "/stub/bin:/usr/bin:/opt/homebrew/bin")
        == "/stub/bin:/usr/bin:/opt/homebrew/bin")
    #expect(Sidecar.searchPath(login: nil, inherited: "/usr/bin:/bin") == "/usr/bin:/bin")
}

/// A stand-in shell that greets like a profile does, then runs the command it was handed.
@MainActor @Test func loginShellPathIsReadPastProfileOutput() throws {
    let shell = FileManager.default.temporaryDirectory.appending(path: "yorozu-shell-\(UUID().uuidString)")
    let script = "#!/bin/sh\necho 'Welcome back'\nPATH=/stub/bin:/usr/bin:/bin\n[ \"$1\" = -lc ] && exec /bin/sh -c \"$2\"\n"
    try Data(script.utf8).write(to: shell)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    defer { try? FileManager.default.removeItem(at: shell) }

    #expect(Sidecar.path(fromLoginShell: shell.path) == "/stub/bin:/usr/bin:/bin")
    #expect(Sidecar.path(fromLoginShell: "/usr/bin/false") == nil)
    #expect(Sidecar.path(fromLoginShell: "/nonexistent/shell") == nil)
}
