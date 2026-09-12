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

    /// One per app, not one per `RootView` value. SwiftUI re-runs a `@State` initializer every
    /// time it rebuilds the view struct and keeps only the first result, so `Session()` inline
    /// would leave a second session behind — and now that ``RelayClient`` reconnects forever,
    /// that second session is a second socket rejoining the room for the life of the process.
    static let shared = Session()

    private init() {
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
                transport: try RelayClient(
                    pairing: stored.pairing,
                    identity: stored.identity,
                    paired: stored.paired == true,
                    onPaired: PairingStore.markPaired
                ),
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = Session.shared
    /// Set once the user has pressed "Get started", so the splash is shown only before that.
    @State private var pairing = false
    /// The thread ids pushed on the list's stack: at most one, and what lets the app open a
    /// thread by itself rather than waiting to be tapped.
    @State private var path: [String] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            // The pairing string is a `yorozu://` link: tapped in Messages, it pairs the phone.
            .onOpenURL { url in
                do { try session.pair(with: url.absoluteString) } catch { pairing = true }
            }
            // iOS suspends the app and its socket with it. Coming back is the moment to re-dial,
            // rather than waiting out a backoff that ran down while nothing was executing.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { session.model?.reconnect() }
            }
    }

    @ViewBuilder private var content: some View {
        if let model = session.model {
            ThreadListView(
                threads: model.threads,
                path: $path,
                onCreate: { path = [model.newDraft().id] },
                onRename: { model.rename($0, to: $1) },
                onArchive: model.archive
            ) { thread in
                ChatView(model: model, thread: thread)
                    .toolbar {
                        Button("Unpair", systemImage: "qrcode") { session.unpair() }
                    }
            }
            // Launch and every return to the foreground land here: pick up where the day left
            // off while it is still warm, and start on a blank one when it is not.
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                path = [threadToOpen(model.threads) ?? model.newDraft().id]
            }
            // Backing out of a draft without sending is what discards it.
            .onChange(of: path) { old, new in
                if let left = old.first, !new.contains(left) { model.discardDraft(left) }
            }
        } else if pairing {
            PairView(onPair: pair)
        } else {
            SplashView { pairing = true }
        }
    }

    /// Returns the message the pairing screens show, or nil when the code was good.
    private func pair(with text: String) -> String? {
        do {
            try session.pair(with: text)
            return nil
        } catch {
            return "Not a Yorozu pairing code."
        }
    }
}
