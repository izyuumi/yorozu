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
    /// What the thread list's navigation stack starts out holding, decided the moment the model
    /// exists rather than after the list has drawn. The cache is read synchronously in
    /// ``ChatModel``'s initialiser, so the answer is already known here — and knowing it here is
    /// what keeps the chat from appearing a frame after the list it was pushed onto.
    private(set) var openPath: [String] = []

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
            openPath = [threadToOpen(model.threads) ?? model.newDraft().id]
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
    /// thread by itself rather than waiting to be tapped. Seeded from the session, which decided
    /// it before this view was ever built, so the first frame is already the chat.
    @State private var path: [String] = Session.shared.openPath
    @State private var settings = false
    /// Whether the app has actually been away, rather than merely dimmed by a Control Centre
    /// swipe. Only a real return to the foreground re-decides which thread is open — the launch
    /// case is already decided, and re-deciding it would undo the seeding above.
    @State private var wasBackgrounded = false

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
                unread: model.unread,
                connection: ConnectionState(state: model.state, ownerOnline: model.ownerOnline),
                path: $path,
                onCreate: { path = [model.newDraft().id] },
                onRename: { model.rename($0, to: $1) },
                onArchive: model.setArchived,
                onPin: model.setPinned,
                onRefresh: model.refresh,
                // Search reaches into what this phone has cached of each thread, which is the
                // only text it can search offline and is usually the whole thread anyway.
                messageText: { id in
                    (model.events[id] ?? []).compactMap {
                        if case .message(let data) = $0.payload { return data.text }
                        return nil
                    }
                    .joined(separator: " ")
                },
                onSettings: { settings = true }
            ) { thread in
                ChatView(model: model, thread: thread)
            }
            // Unpairing lives in Settings behind a confirmation now, which is the only place it
            // belongs: it is not something to do by mistyping a tap in a chat.
            .sheet(isPresented: $settings) {
                // Read when the sheet opens rather than held: `markPaired` writes the pairing
                // date behind our back, and Settings is opened far too rarely for one Keychain
                // read to be worth caching.
                let stored = PairingStore.load()
                SettingsView(
                    status: MacStatus(state: model.state, ownerOnline: model.ownerOnline),
                    relayUrl: stored?.pairing.relayUrl ?? "—",
                    pairedAt: stored?.pairedAt,
                    onUnpair: session.unpair
                )
            }
            // Every return to the foreground lands here: pick up where the day left off while it
            // is still warm, and start on a blank one when it is not. Launch is not handled here
            // — `path` was already seeded before the first frame, which is what stops the list
            // flashing past on the way to the chat.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { wasBackgrounded = true }
                guard phase == .active, wasBackgrounded else { return }
                wasBackgrounded = false
                path = [threadToOpen(model.threads) ?? model.newDraft().id]
            }
            // Pairing mid-session is the other way a model appears, and it decides an opening
            // thread of its own.
            .onChange(of: session.openPath) { _, opened in path = opened }
            // Backing out of a draft without sending is what discards it. Whatever is on top is
            // the thread being read, so a reply arriving in it does not raise an unread dot.
            .onChange(of: path, initial: true) { old, new in
                if let left = old.first, !new.contains(left) { model.discardDraft(left) }
                model.openThread = new.last
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
