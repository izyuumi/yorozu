import SwiftUI
import UIKit
import UserNotifications
import YorozuShared

#if DEBUG
/// Local transport for deterministic showcase screenshots. Production never enters this path.
private actor ShowcaseTransport: ChatTransport {
    func connect() -> AsyncStream<TransportUpdate> {
        AsyncStream { continuation in
            continuation.yield(.ownerOnline(true))
            continuation.yield(.state(.paired))
        }
    }

    func send(_ event: YorozuEvent) async throws {}
    func close() async {}
}
#endif

@main
struct YorozuApp: App {
    /// APNs has to be answered by an app delegate — there is no SwiftUI form of the device
    /// token callback — so the one this app has exists for that and nothing else.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The phone's pairing lifecycle, which is the one thing about its chat that is not shared: the
/// stored pairing, and the ``ChatModel`` built over a ``RelayClient`` for it. The model, the
/// views and the thread cache all come from `YorozuShared`; the Mac builds the same model over
/// its local socket instead.
@MainActor
@Observable
final class Session {
    struct NotificationOpen: Equatable {
        let id = UUID()
        let threadId: String
        let notificationClass: String?
        let eventRef: String?
        let lastReadAt: Double?
        let syncRevision: Int
    }

    private(set) var model: ChatModel?
    private(set) var failure: String?
    /// What the thread list's navigation stack starts out holding, decided the moment the model
    /// exists rather than after the list has drawn. The cache is read synchronously in
    /// ``ChatModel``'s initialiser, so the answer is already known here — and knowing it here is
    /// what keeps the chat from appearing a frame after the list it was pushed onto.
    private(set) var openPath: [String] = []
    /// A tap is also a scroll request. Kept separate from the navigation path so tapping while
    /// that same thread is already on the stack still moves the existing timeline.
    private(set) var notificationOpen: NotificationOpen?
    /// A notification can name a thread missing from the cold cache. Hold only its opaque ref;
    /// the next authoritative thread list resolves it without trusting push content.
    private var pendingThreadRef: String?
    private var pendingNotificationClass: String?
    private var pendingEventRef: String?
    /// The transport, kept apart from the model so push tokens have somewhere to be registered:
    /// the relay is the thing that holds them, because it is the thing that calls APNs.
    private(set) var relay: RelayClient?
    /// Why this phone cannot be woken, when it cannot. Nothing shows it yet; it is here so the
    /// failure is recorded rather than swallowed.
    var pushFailure: String?
    /// The device token, kept so a re-pairing can register it with the new relay without
    /// waiting for iOS to hand out another one — it only does that when it changes.
    private var deviceToken: String?

    /// One per app, not one per `RootView` value. SwiftUI re-runs a `@State` initializer every
    /// time it rebuilds the view struct and keeps only the first result, so `Session()` inline
    /// would leave a second session behind — and now that ``RelayClient`` reconnects forever,
    /// that second session is a second socket rejoining the room for the life of the process.
    static let shared = Session()

    private init() {
        #if DEBUG
        if launchArgument("yorozuShowcase") != nil || launchArgument("yorozuScene") != nil {
            let model = ChatModel(transport: ShowcaseTransport())
            E2EHarness.attach(to: model)
            model.start()
            self.model = model
            let showcase = launchArgument("yorozuShowcase") ?? launchArgument("yorozuScene")
            openPath = showcase == "threads" ? [] : model.threads.prefix(1).map(\.id)
            return
        }
        #endif
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

    /// Asks for notifications, once, at the moment they start to make sense: something is paired,
    /// so there is now something that could need to wake you.
    func requestNotifications() {
        // Never during a screenshot run: the permission alert is modal, so it — and not the
        // thread underneath it — would be the picture.
        guard launchArgument("yorozuShowcase") == nil, launchArgument("yorozuScene") == nil else { return }
        Task {
            let granted = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            // Registering regardless of the answer would be dishonest, and pointless: without
            // authorization there is nothing APNs would deliver.
            guard granted == true else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// The device token, on its way to the relay. Held too, so a later pairing can register it
    /// without waiting on iOS to reissue one — it only does that when the token changes.
    func registerPush(deviceToken: String) {
        self.deviceToken = deviceToken
        guard let relay else { return }
        Task { await relay.registerPush(deviceToken: deviceToken) }
    }

    func unpair() {
        model?.close()
        model = nil
        relay = nil
        PairingStore.clear()
        NotificationPreview.clearKey()
        CacheStore.clear()
        // The thread titles the picker offers, and anything half-shared, belong to the pairing
        // just as much as the cache does.
        if let directory = ShareBox.directory() { ShareBox.clear(in: directory) }
    }

    /// Sends everything the share extension has left in the App Group container, oldest first.
    ///
    /// Called on the `yorozu://share` open and again every time the app comes to the foreground:
    /// an extension's `open` is not guaranteed to arrive, and a share that is on disk has been
    /// confirmed by the person who made it. Nothing is drained before there is a model to send
    /// it with — the files simply wait for the next foreground.
    func drainShares() {
        guard let model, let directory = ShareBox.directory() else { return }
        for payload in ShareBox.takeAll(in: directory) {
            let thread = payload.threadId.flatMap { id in model.threads.first { $0.id == id } }
                ?? model.newDraft()
            model.send(payload.text, in: thread.id, attachment: payload.attachment)
            openPath = [thread.id]
        }
    }

    /// Opens a thread by id, for a `yorozu://thread/<id>`. An id this device has never heard of
    /// is ignored rather than pushed: an empty chat with no way back to it is worse than the tap
    /// doing nothing.
    func open(threadId: String) {
        guard model?.threads.contains(where: { $0.id == threadId }) == true else { return }
        openPath = [threadId]
    }

    /// Opens a thread by the opaque reference a push carries — a tapped notification, which
    /// knows nothing else about its thread.
    ///
    /// The mapping only exists here. The relay sent a reference precisely so that it could not
    /// do this itself, and the phone resolves it by hashing the thread ids it already holds.
    @discardableResult
    func open(threadRef: String, notificationClass: String? = nil, eventRef: String? = nil) -> Bool {
        let match = model?.threads.first { YorozuCrypto.threadRef($0.id) == threadRef }
        guard let match else {
            pendingThreadRef = threadRef
            pendingNotificationClass = notificationClass
            pendingEventRef = eventRef
            return false
        }
        pendingThreadRef = nil
        pendingNotificationClass = nil
        pendingEventRef = nil
        notificationOpen = NotificationOpen(
            threadId: match.id,
            notificationClass: notificationClass,
            eventRef: eventRef,
            lastReadAt: match.lastReadAt,
            syncRevision: model?.syncRevision ?? 0
        )
        openPath = [match.id]
        return true
    }

    func clearNotificationOpen() { notificationOpen = nil }

    /// The few threads the share sheet's picker offers, newest first. Archived threads and the
    /// unsent draft are left out: neither is somewhere to put a link.
    private func publishThreads(_ model: ChatModel? = nil) {
        guard let model = model ?? self.model, let directory = ShareBox.directory() else { return }
        let threads = model.threads
            .filter { !$0.archived && $0.id != model.draft?.id }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(5)
        ShareBox.save(threads: Array(threads), in: directory)
    }

    private func connect(_ stored: PairingStore.Stored) {
        do {
            let notificationKey = try YorozuCrypto.deriveSessionKey(
                myPriv: stored.identity.sessionPrivateKey,
                theirPub: Data(base64URLEncoded: stored.pairing.macPubkey) ?? Data()
            )
            NotificationPreview.save(key: notificationKey)
            let relay = try RelayClient(
                pairing: stored.pairing,
                identity: stored.identity,
                paired: stored.paired == true,
                onPaired: PairingStore.markPaired
            )
            self.relay = relay
            let model = ChatModel(transport: relay, cache: CacheStore.open())
            E2EHarness.attach(to: model)
            // The harness owns `onPaired` when it is running at all, so this is added to
            // whatever is already there rather than written over it.
            let onPaired = model.onPaired
            model.onPaired = { [weak self] in
                onPaired?()
                self?.drainShares()
            }
            // The share extension cannot read the encrypted thread cache, so the picker's
            // titles are put where it can: here at startup from the cache, and again whenever
            // the runtime sends a fresh list.
            let onThreads = model.onThreads
            model.onThreads = { [weak self] in
                onThreads?()
                self?.publishThreads()
                if let ref = self?.pendingThreadRef {
                    self?.open(
                        threadRef: ref,
                        notificationClass: self?.pendingNotificationClass,
                        eventRef: self?.pendingEventRef
                    )
                }
            }
            model.start()
            self.model = model
            publishThreads(model)
            // Something is paired now, so being woken by it starts to make sense. A token this
            // phone was already given is handed straight to the new relay; otherwise the ask is
            // what eventually produces one.
            if let deviceToken {
                Task { await relay.registerPush(deviceToken: deviceToken) }
            } else {
                requestNotifications()
            }
            // Land on the thread list; Yumi prefers choosing over being dropped into the latest.
            // The screenshot harness is the one exception: it opens the thread it seeded,
            // unless what it seeded is the list itself.
            let showcase = launchArgument("yorozuShowcase") ?? launchArgument("yorozuScene")
            openPath =
                showcase == nil || showcase == "threads"
                ? [] : model.threads.map(\.id).prefix(1).map { $0 }
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
    /// Screenshot only: `-yorozuShowcase share` draws the share extension's composer here,
    /// because a simulator cannot be made to open a real share sheet.
    @State private var shareShowcase = ChatShowcase.share

    var body: some View {
        content
            .overlay {
                PhoneWorkingBezel(active: session.model?.generating.isEmpty == false)
                    .ignoresSafeArea(.container)
            }
            // Four things arrive as a `yorozu://` link and they are told apart by the host, not
            // by trying each parser in turn: `pair` is the pairing string tapped in Messages,
            // `thread` and `ref` name a thread to open, `share` is the share extension handing
            // over. Anything else is not ours.
            .onOpenURL { url in
                switch url.host() {
                case "thread":
                    // `yorozu://thread/<id>`, so the id is the path with its leading slash off.
                    // Decoded once, by `path`: decoding again would eat a literal `%` in an id.
                    session.open(threadId: String(url.path(percentEncoded: false).dropFirst()))
                case "ref":
                    // `yorozu://ref/<threadRef>` — a notification being tapped, which knows the
                    // thread only by the reference a push carried.
                    session.open(threadRef: String(url.path(percentEncoded: false).dropFirst()))
                case "share":
                    // The token names the file, but everything waiting is drained either way —
                    // see ``Session/drainShares()``.
                    session.drainShares()
                default:
                    do { try session.pair(with: url.absoluteString) } catch { pairing = true }
                }
            }
            // iOS suspends the app and its socket with it. Coming back is the moment to re-dial,
            // rather than waiting out a backoff that ran down while nothing was executing — and
            // the moment to pick up anything shared while it was away.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // A background drain hangs up so the OS can suspend the app cleanly, so
                // coming back may be a fresh dial rather than a reconnect. `start()` does
                // nothing when a stream is already running.
                session.model?.start()
                session.model?.reconnect()
                session.drainShares()
            }
            // Half of "genuinely reading": a thread on screen in an app nobody is looking at is
            // not being read, and must not report that it was. Kept apart from the switch above
            // so the reconnect only happens on an actual transition into `.active`.
            .onChange(of: scenePhase, initial: true) { _, phase in
                session.model?.foreground = phase == .active
            }
            // The badge counts threads, not messages: it is the same number the list's dots add
            // up to. Zero clears it rather than drawing a nought.
            .onChange(of: session.model?.unreadCount ?? 0, initial: true) { _, count in
                Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
            }
    }

    @ViewBuilder private var content: some View {
        if let model = session.model {
            ThreadListView(
                threads: model.threads,
                connection: ConnectionState(state: model.state, ownerOnline: model.ownerOnline),
                path: $path,
                onCreate: { path = [model.newDraft().id] },
                onRename: { model.rename($0, to: $1) },
                onArchive: model.setArchived,
                onPin: model.setPinned,
                onRead: { thread, read in
                    read ? model.markRead(thread.id) : model.markUnread(thread)
                },
                onReadAll: model.markAllRead,
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
                exportMarkdown: model.markdown(of:),
                onSettings: { settings = true }
            ) { thread in
                let notification = session.notificationOpen.flatMap { $0.threadId == thread.id ? $0 : nil }
                ChatView(
                    model: model,
                    thread: thread,
                    resumeRequest: notification?.id,
                    notificationClass: notification?.notificationClass,
                    notificationEventRef: notification?.eventRef,
                    lastReadAt: notification?.lastReadAt,
                    notificationSyncRevision: notification?.syncRevision
                ) {
                    path = [model.newDraft().id]
                }
            }
            // Unpairing lives in Settings behind a confirmation now, which is the only place it
            // belongs: it is not something to do by mistyping a tap in a chat.
            .sheet(isPresented: $settings) {
                // Read when the sheet opens rather than held: `markPaired` writes the pairing
                // date behind our back, and Settings is opened far too rarely for one Keychain
                // read to be worth caching.
                let stored = PairingStore.load()
                SettingsView(
                    status: ConnectionState(state: model.state, ownerOnline: model.ownerOnline),
                    relayUrl: stored?.pairing.relayUrl ?? "—",
                    pairedAt: stored?.pairedAt,
                    onUnpair: session.unpair,
                    model: model
                )
            }
            .sheet(isPresented: $shareShowcase) {
                ShareComposeView(
                    threads: model.threads.prefix(5).map(ShareThread.init),
                    load: { .link(URL(string: "https://cooking.example.com/roast-chicken")!) },
                    send: { _ in },
                    cancel: { shareShowcase = false }
                )
            }
            // Pairing mid-session is the other way a model appears, and it decides an opening
            // thread of its own.
            .onChange(of: session.openPath) { _, opened in path = opened }
            // Backing out of a draft without sending is what discards it. Whatever is on top is
            // the thread being read, so a reply arriving in it does not raise an unread dot.
            .onChange(of: path, initial: true) { old, new in
                if let left = old.first, !new.contains(left) { model.discardDraft(left) }
                if session.notificationOpen?.threadId != new.last { session.clearNotificationOpen() }
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
            return String(localized: "Not a Yorozu pairing code.")
        }
    }
}

/// A running turn follows the window's own corner geometry. Placing this at the scene root is
/// important: inside a pushed chat, `ContainerRelativeShape` inherits navigation chrome's
/// asymmetric shape instead of the physical display's four corners.
private struct PhoneWorkingBezel: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        ContainerRelativeShape()
            .strokeBorder(
                Color.blue.opacity(active ? (bright || reduceMotion ? 0.9 : 0.3) : 0),
                lineWidth: 2
            )
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: bright)
            .onChange(of: active, initial: true) { _, running in
                bright = running && !reduceMotion
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
