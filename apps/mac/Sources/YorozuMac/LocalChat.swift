import Foundation
import YorozuShared

/// The Mac's own chat client: one ``ChatModel`` over the sidecar's local socket, so the same
/// threads, traces and approval cards the phone sees are on this machine with no relay hop.
///
/// Started with the app rather than with the window, because a menu bar window only exists
/// while it is open and replies, approval cards and thread lists have to arrive either way.
/// No ``ThreadCache``: this machine's own thread logs are the originals, and the sidecar hands
/// them over as a `sync_delta` on connect.
@MainActor
enum LocalChat {
    static let model = ChatModel(
        transport: LocalSocketTransport(path: LocalSocketTransport.defaultPath()),
        device: "mac"
    )

    static func start() {
        model.onThreads = {
            // The line a `swift run` smoke test looks for: the list arrived over the socket.
            // Flushed like `Permission.logAll`, because stdout is block-buffered whenever it is
            // not a terminal and the app is killed rather than asked to exit.
            print("YOROZU-MAC threads=\(model.threads.count) [\(model.threads.map(\.title).joined(separator: ", "))]")
            fflush(stdout)
        }
        Task {
            // The sidecar is spawned a moment before this and binds the socket when it starts,
            // so there is nothing to connect to yet. Ten seconds is far longer than Node takes.
            let path = LocalSocketTransport.defaultPath()
            var waited = 0
            while !FileManager.default.fileExists(atPath: path), waited < 100 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            model.start()
        }
    }
}
