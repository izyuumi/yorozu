import SwiftUI
import YorozuShared

@main
struct YorozuApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// The phone's pairing lifecycle, which is the one thing about its chat that is not shared: the
/// stored pairing, and the ``ChatModel`` built over a ``RelayClient`` for it. The model, the
/// views and the thread cache all come from `YorozuShared`; the Mac builds the same model over
/// its local socket instead.
@MainActor
@Observable
final class Session {
    private(set) var model: ChatModel?
    private(set) var failure: String?

    init() {
        if let injected = launchArgument("yorozuPair") {
            // Surface the reason rather than silently falling back to the scanner.
            do { try pair(with: injected) } catch { failure = error.localizedDescription }
        } else if let stored = PairingStore.load() {
            connect(stored)
        }
    }

    /// Accepts an untrusted QR string, persists it with a fresh device identity, and connects.
    func pair(with text: String) throws {
        let stored = PairingStore.Stored(
            pairing: try QrPayload.decode(text),
            identity: .generate()
        )
        try PairingStore.save(stored)
        connect(stored)
    }

    func unpair() {
        model?.close()
        model = nil
        PairingStore.clear()
        CacheStore.clear()
    }

    private func connect(_ stored: PairingStore.Stored) {
        do {
            let model = ChatModel(
                transport: try RelayClient(pairing: stored.pairing, identity: stored.identity),
                cache: CacheStore.open()
            )
            E2EHarness.attach(to: model)
            model.start()
            self.model = model
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct RootView: View {
    @State private var session = Session()

    var body: some View {
        if let model = session.model {
            ThreadListView(
                threads: model.threads,
                onCreate: { model.createThread(title: $0) },
                onArchive: model.archive
            ) { thread in
                ChatView(model: model, thread: thread)
                    .toolbar {
                        Button("Unpair", systemImage: "qrcode") { session.unpair() }
                    }
            }
        } else {
            ScannerView { text in
                do {
                    try session.pair(with: text)
                    return nil
                } catch {
                    return "Not a Yorozu pairing code."
                }
            }
        }
    }
}
