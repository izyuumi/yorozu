import CryptoKit
import SwiftUI
import UIKit
import UserNotifications
import YorozuShared

/// Local transport for reviewer demo mode. It answers only typed messages and keeps all state
/// in memory, so it cannot reach a paired Mac or its cache.
private actor DemoTransport: ChatTransport {
    private var continuation: AsyncStream<TransportUpdate>.Continuation?

    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        self.continuation = continuation
        continuation.yield(.ownerOnline(true))
        continuation.yield(.state(.paired))
        continuation.onTermination = { [weak self] _ in Task { await self?.disconnected() } }
        return stream
    }

    func send(_ event: YorozuEvent) async throws {
        continuation?.yield(.event(YorozuEvent(
            id: UUID().uuidString,
            threadId: event.threadId,
            ts: Int(Date().timeIntervalSince1970 * 1000),
            agentId: "main",
            payload: .receipt(ReceiptData(eventId: event.id))
        )))
        guard case .message(let message) = event.payload, message.role == .user else { return }
        let continuation = continuation
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            continuation?.yield(.event(YorozuEvent(
                id: UUID().uuidString,
                threadId: event.threadId,
                ts: Int(Date().timeIntervalSince1970 * 1000),
                agentId: "main",
                payload: .message(MessageData(
                    role: .agent,
                    text: "This is a demo, so no agent is connected. Pair Yorozu with the free Mac app at yorozu.yumi.to to talk to OpenClaw, Claude Code or Codex on your own Mac.",
                    done: true
                ))
            )))
        }
    }

    func close() {
        continuation?.finish()
        continuation = nil
    }

    private func disconnected() { continuation = nil }
}

#if DEBUG
/// Local transport for deterministic showcase screenshots. Production never enters this path.
private actor ShowcaseTransport: ChatTransport {
    private var continuation: AsyncStream<TransportUpdate>.Continuation?

    func connect() -> AsyncStream<TransportUpdate> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.ownerOnline(launchArgument("yorozuShowcase") != "queued"))
            continuation.yield(.state(.paired))
        }
    }

    func send(_ event: YorozuEvent) async throws {}
    func close() async {}
    func deliver(_ event: YorozuEvent) { continuation?.yield(.event(event)) }
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

/// Platform persistence, push and share integration around independent host sessions.
@MainActor
@Observable
final class Session {
    struct NotificationOpen: Equatable {
        let id = UUID()
        let hostID: HostID
        let threadId: String
        let notificationClass: String?
        let eventRef: String?
        let lastReadAt: Double?
        let syncRevision: Int
    }

    struct PendingPairing: Identifiable, Equatable {
        let id = UUID()
        let code: String
        let relayHost: String
        let macKeyFingerprint: String
        let existingHostID: HostID?
    }

    let hosts = MultiHostModel()
    private(set) var model: ChatModel?
    private(set) var failure: String?
    private(set) var isPairing = false
    private(set) var isDemo = false
    private(set) var pendingPairing: PendingPairing?
    private(set) var openPath: [String] = []
    private(set) var hostPath: [HostThreadID] = []
    private(set) var notificationOpen: NotificationOpen?
    private var pendingNotification: (hostID: HostID, ref: String, kind: String?, event: String?)?
    private var relays: [HostID: RelayClient] = [:]
    private(set) var notificationKeys: [HostID: SymmetricKey] = [:]
    private var pairingHostID: HostID?
    private var deviceToken: String?
    private var migrationFailed = false
    private var changingHosts: Set<HostID> = []
    var pushFailure: String?
    static let shared = Session()

    var allModels: [ChatModel] { isDemo || hosts.sessions.isEmpty ? model.map { [$0] } ?? [] : hosts.sessions.map(\.model) }
    var unreadCount: Int { isDemo ? model?.unreadCount ?? 0 : hosts.unreadCount }
    var pairingFailure: String? { failure ?? pairingHostID.flatMap { hosts.session(for: $0)?.model.failure } }
    var showingHosts: Bool {
        !hosts.sessions.isEmpty && (hosts.sessions.count > 1 || !isPairing || hosts.sessions.contains {
            if case .updateRequired = $0.model.compatibility { return true }
            return false
        })
    }

    func finishIncompatiblePairing() {
        guard let pairingHostID, let host = hosts.session(for: pairingHostID),
              case .updateRequired = host.model.compatibility else { return }
        isPairing = false
    }

    private init() {
        #if DEBUG
        if launchArgument("yorozuDemo") != nil { startDemo(); return }
        if launchArgument("yorozuShowcase") != nil || launchArgument("yorozuScene") != nil {
            let transport = ShowcaseTransport()
            let model = ChatModel(transport: transport)
            E2EHarness.attach(to: model)
            model.start()
            self.model = model
            let showcase = launchArgument("yorozuScene") ?? launchArgument("yorozuShowcase")
            openPath = showcase == "threads" || showcase == "thread-search" ? [] : model.threads.prefix(1).map(\.id)
            if launchArgument("yorozuPickerReply") != nil {
                NewThreadShowcase.onFoldersAppear = {
                    NewThreadShowcase.onFoldersAppear = nil
                    Task {
                        let now = Int(Date().timeIntervalSince1970 * 1000)
                        var threads = model.threads
                        guard let index = threads.firstIndex(where: { $0.id == "Standup notes" }) else { return }
                        threads[index].lastActivity = Double(now)
                        threads[index].lastAgentAt = Double(now)
                        threads[index].lastMessage = "Picker regression reply"
                        await transport.deliver(YorozuEvent(
                            id: "picker-reply", threadId: threads[index].id, ts: now, agentId: "main",
                            payload: .message(MessageData(role: .agent, text: "Picker regression reply", done: true))
                        ))
                        await transport.deliver(YorozuEvent(
                            id: "picker-threads", threadId: "", ts: now, agentId: "main",
                            payload: .threadList(ThreadListData(threads: threads))
                        ))
                        // A visible acknowledgement means the test never guesses when delivery finished.
                        var projects = model.projects
                        projects[0].name = "Reply received"
                        await transport.deliver(YorozuEvent(
                            id: "picker-projects", threadId: "", ts: now, agentId: "main",
                            payload: .projectList(ProjectListData(projects: projects))
                        ))
                    }
                }
            }
            return
        }
        #endif
        do {
            if let legacyHostID = PairingStore.legacyHostID {
                NotificationPreview.migrateLegacyKey(to: legacyHostID)
                if let directory = ShareBox.directory(),
                   !ShareBox.migrateLegacy(to: ShareHost(id: legacyHostID, label: "Mac · \(String(legacyHostID.prefix(12)))"), in: directory) {
                    throw YorozuCrypto.CryptoError.malformed("Could not migrate pending shares. Restart Yorozu to retry.")
                }
            }
            try PairingStore.migrateLegacy()
            let records = try PairingStore.loadAllRequired()
            hosts.lastUsedHostID = UserDefaults.standard.string(forKey: "last-used-host")
            for stored in records {
                #if DEBUG
                connect(stored, start: launchArgument("yorozuRemoveHost") == nil)
                #else
                connect(stored)
                #endif
            }
            #if DEBUG
            if let removed = launchArgument("yorozuRemoveHost") {
                Task {
                    await removeHost(removed)
                    hosts.start()
                }
            }
            #endif
        } catch {
            migrationFailed = true
            failure = error.localizedDescription
        }
        #if DEBUG
        do {
            if let injected = launchArgument("yorozuPair") { try pair(with: injected) }
            if let second = launchArgument("yorozuPairSecond") { try pair(with: second) }
        } catch { failure = error.localizedDescription }
        #endif
    }

    private func pending(code: String, payload: QrPayload, existingHostID: HostID? = nil) -> PendingPairing {
        PendingPairing(code: code, relayHost: payload.relayHost ?? payload.relayUrl,
                       macKeyFingerprint: payload.macKeyFingerprint ?? String(localized: "unreadable key"),
                       existingHostID: existingHostID)
    }

    /// Duplicate detection happens before creating an identity or redeeming a one-time code.
    func pair(with text: String) throws {
        guard !migrationFailed else { throw PairingFailure.migration }
        let payload = try QrPayload.decode(text)
        guard let payloadHostID = payload.hostID else { throw YorozuCrypto.CryptoError.malformed("invalid Mac key") }
        guard !changingHosts.contains(payloadHostID) else { throw PairingFailure.busy }
        if let existing = PairingStore.loadAll().first(where: { $0.hostID == payloadHostID || $0.pairing.macPubkey == payload.macPubkey }) {
            pendingPairing = pending(code: text, payload: payload, existingHostID: existing.hostID)
            throw PairingFailure.duplicate
        }
        let stored = PairingStore.Stored(pairing: payload, identity: .generate())
        try PairingStore.save(stored)
        failure = nil
        pairingHostID = stored.hostID
        isPairing = true
        connect(stored)
    }

    enum PairingFailure: LocalizedError {
        case duplicate, migration, busy
        var errorDescription: String? {
            switch self {
            case .duplicate: String(localized: "Already connected. Choose Repair connection to pair this host again.")
            case .migration: String(localized: "Could not migrate existing pairing. Restart Yorozu before adding a host.")
            case .busy: String(localized: "This host is being updated. Try again when it finishes.")
            }
        }
    }

    func handlePairingLink(_ url: URL) {
        guard url.host()?.lowercased() == "pair", let payload = try? QrPayload.decode(url.absoluteString), payload.hostID != nil else { return }
        if PairingStore.loadAll().isEmpty {
            if isDemo { exitDemo() }
            do { try pair(with: url.absoluteString) } catch { failure = error.localizedDescription }
            return
        }
        let existing = PairingStore.loadAll().first { $0.hostID == payload.hostID || $0.pairing.macPubkey == payload.macPubkey }
        pendingPairing = pending(code: url.absoluteString, payload: payload, existingHostID: existing?.hostID)
    }

    func confirmPairing(_ pending: PendingPairing) async {
        pendingPairing = nil
        do {
            if let hostID = pending.existingHostID, let old = PairingStore.load(hostID: hostID) {
                let payload = try QrPayload.decode(pending.code)
                guard payload.hostID == hostID else { throw PairingFailure.duplicate }
                guard changingHosts.insert(hostID).inserted else { return }
                defer { changingHosts.remove(hostID); publishThreads() }
                let oldKeys = notificationKeys
                await hosts.remove(hostID)
                await clearNotifications(for: hostID, keys: oldKeys)
                NotificationPreview.clearKey(hostID: hostID)
                notificationKeys[hostID] = nil
                let stored = PairingStore.Stored(pairing: payload, identity: .generate(), nickname: old.nickname)
                do { try PairingStore.save(stored) }
                catch { connect(old); throw error }
                relays[hostID] = nil
                pairingHostID = hostID
                isPairing = true
                failure = nil
                connect(stored)
            } else {
                try pair(with: pending.code)
            }
        } catch { failure = error.localizedDescription }
    }

    func cancelPendingPairing() { pendingPairing = nil }

    func setNickname(_ nickname: String, for hostID: HostID) {
        let value = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        do {
            try PairingStore.updateNickname(value.isEmpty ? nil : value, hostID: hostID)
            hosts.session(for: hostID)?.nickname = value.isEmpty ? nil : value
            publishThreads()
        } catch { failure = error.localizedDescription }
    }

    func rememberHost(_ hostID: HostID) {
        hosts.lastUsedHostID = hostID
        UserDefaults.standard.set(hostID, forKey: "last-used-host")
    }

    func removeHost(_ hostID: HostID) async {
        guard hosts.session(for: hostID) != nil, changingHosts.insert(hostID).inserted else { return }
        defer { changingHosts.remove(hostID); publishThreads() }
        let keys = notificationKeys
        await hosts.remove(hostID)
        do {
            try CacheStore.clear(hostID: hostID)
            try PairingStore.remove(hostID: hostID)
        } catch {
            failure = error.localizedDescription
            if let stored = PairingStore.load(hostID: hostID) { connect(stored) }
            return
        }
        relays[hostID] = nil
        NotificationPreview.clearKey(hostID: hostID)
        notificationKeys[hostID] = nil
        if let directory = ShareBox.directory() { ShareBox.clear(hostID: hostID, in: directory) }
        if hostPath.contains(where: { $0.hostID == hostID }) { hostPath = [] }
        if notificationOpen?.hostID == hostID { notificationOpen = nil }
        if pendingNotification?.hostID == hostID { pendingNotification = nil }
        if pairingHostID == hostID { pairingHostID = nil; isPairing = false }
        model = hosts.sessions.first?.model
        if hosts.lastUsedHostID == hostID {
            hosts.lastUsedHostID = hosts.sessions.first?.id
            UserDefaults.standard.set(hosts.lastUsedHostID, forKey: "last-used-host")
        }
        await clearNotifications(for: hostID, keys: keys)
        try? await UNUserNotificationCenter.current().setBadgeCount(hosts.unreadCount)
        #if DEBUG
        print("YOROZU-E2E-REMOVED [\(hostID)] remaining=\(hosts.sessions.count)")
        #endif
    }

    private func clearNotifications(for hostID: HostID, keys: [HostID: SymmetricKey]) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            NotificationFallback.authenticatedPreview(userInfo: $0.request.content.userInfo, keys: keys)?.hostID == hostID
        }.map { $0.request.identifier })
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            NotificationFallback.authenticatedPreview(userInfo: $0.content.userInfo, keys: keys)?.hostID == hostID
        }.map(\.identifier))
        if hosts.sessions.isEmpty && PairingStore.loadAll().isEmpty {
            center.removeAllDeliveredNotifications()
            center.removeAllPendingNotificationRequests()
        }
    }

    func startDemo() {
        guard hosts.sessions.isEmpty else { return }
        model?.close()
        failure = nil; isPairing = false; isDemo = true; openPath = []
        notificationOpen = nil; pendingNotification = nil
        let model = ChatModel(transport: DemoTransport(), cache: nil)
        model.previewThreads()
        model.previewChat(in: "Invoices")
        model.previewApproval(in: "Fix the flaky relay test")
        model.previewProgress(in: "Tidy the icon script")
        model.previewQuestion(in: "Kyoto in April")
        model.start()
        self.model = model
    }

    func exitDemo() {
        guard isDemo else { return }
        model?.close(); model = nil
        failure = nil; isPairing = false; isDemo = false; openPath = []
        notificationOpen = nil; pendingNotification = nil
    }

    func requestNotifications() {
        guard !isDemo, launchArgument("yorozuShowcase") == nil, launchArgument("yorozuScene") == nil else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func registerPush(deviceToken: String) {
        self.deviceToken = deviceToken
        guard !isDemo else { return }
        for relay in relays.values { Task { await relay.registerPush(deviceToken: deviceToken) } }
    }

    /// Settings' "Re-register": asks APNs for the token again and tells every relay, which drops
    /// any other record holding the same token — a stale one from an earlier pairing is what
    /// doubles each alert with a "New activity" copy.
    func reregisterPush() {
        pushFailure = nil
        if let deviceToken { registerPush(deviceToken: deviceToken) }
        requestNotifications()
    }

    func drainShares() {
        guard !isDemo, !migrationFailed, let directory = ShareBox.directory() else { return }
        let ready = ShareBox.takeAll(in: directory, matching: { payload in
            guard let id = payload.hostID, let host = hosts.session(for: id) else { return false }
            return payload.threadId == nil || host.model.threads.contains { $0.id == payload.threadId }
        })
        for payload in ready {
            guard let hostID = payload.hostID, let host = hosts.session(for: hostID) else { continue }
            let thread: ThreadSummary
            if let id = payload.threadId {
                guard let existing = host.model.threads.first(where: { $0.id == id }) else { continue }
                thread = existing
            } else { thread = host.model.newDraft() }
            host.model.send(payload.text, in: thread.id, attachments: payload.attachment.map { [$0] } ?? [])
            rememberHost(hostID)
            hostPath = [HostThreadID(hostID: hostID, threadID: thread.id)]
        }
    }

    /// Legacy unqualified links are usable only with exactly one host.
    func open(threadId: String, hostID: HostID? = nil) {
        guard let id = hostID ?? (hosts.sessions.count == 1 ? hosts.sessions.first?.id : nil),
              let host = hosts.session(for: id), host.model.threads.contains(where: { $0.id == threadId }) else { return }
        hostPath = [HostThreadID(hostID: id, threadID: threadId)]
        rememberHost(id)
    }

    @discardableResult
    func open(threadRef: String, hostID: HostID? = nil, notificationClass: String? = nil, eventRef: String? = nil) -> Bool {
        guard let id = hostID ?? (hosts.sessions.count == 1 ? hosts.sessions.first?.id : nil), let host = hosts.session(for: id) else { return false }
        guard let match = host.model.threads.first(where: { YorozuCrypto.threadRef($0.id) == threadRef }) else {
            pendingNotification = (id, threadRef, notificationClass, eventRef)
            return false
        }
        pendingNotification = nil
        notificationOpen = NotificationOpen(hostID: id, threadId: match.id, notificationClass: notificationClass,
                                            eventRef: eventRef, lastReadAt: match.lastReadAt, syncRevision: host.model.syncRevision)
        hostPath = [HostThreadID(hostID: id, threadID: match.id)]
        rememberHost(id)
        return true
    }

    func clearNotificationOpen() { notificationOpen = nil }

    func publishThreads() {
        // A replacement briefly removes a live model. Keep the complete share destination
        // snapshot until it finishes, so another host never becomes an implicit destination.
        guard changingHosts.isEmpty else { return }
        guard let directory = ShareBox.directory(), !isDemo else { return }
        let threads = hosts.threads.filter { item in
            !item.thread.archived && hosts.model(for: item.id)?.isDraft(item.id.threadID) == false
        }.prefix(10).map { item in
            ShareThread(id: item.id.threadID, title: item.thread.displayTitle, hostID: item.id.hostID, hostLabel: item.hostLabel)
        }
        ShareBox.save(hosts: hosts.sessions.map { ShareHost(id: $0.id, label: $0.label) }, threads: threads, in: directory)
    }

    private func connect(_ stored: PairingStore.Stored, start: Bool = true) {
        let hostID = stored.hostID
        do {
            let key = try YorozuCrypto.deriveSessionKey(myPriv: stored.identity.sessionPrivateKey,
                                                      theirPub: Data(base64URLEncoded: stored.pairing.macPubkey) ?? Data())
            if !NotificationPreview.save(key: key, hostID: hostID) {
                pushFailure = String(localized: "Could not save this host’s notification preview key.")
            }
            let relay = try RelayClient(pairing: stored.pairing, identity: stored.identity, paired: stored.paired == true,
                                        counters: PairingCounterStorage(hostID: hostID), onPaired: { PairingStore.markPaired(hostID: hostID, expectedIdentity: stored.identity.sessionPublicKey) })
            let model = ChatModel(transport: relay, cache: try CacheStore.open(hostID: hostID))
            #if DEBUG
            E2EHarness.attach(to: model)
            #endif
            let onPaired = model.onPaired
            model.onPaired = { [weak self] in
                onPaired?()
                guard let self else { return }
                if self.pairingHostID == hostID { self.isPairing = false; self.pairingHostID = nil }
                self.drainShares()
                if let token = self.deviceToken { Task { await relay.registerPush(deviceToken: token) } }
                else { self.requestNotifications() }
            }
            let onThreads = model.onThreads
            model.onThreads = { [weak self] in
                onThreads?()
                guard let self else { return }
                self.publishThreads()
                self.drainShares()
                if let pending = self.pendingNotification, pending.hostID == hostID {
                    self.open(threadRef: pending.ref, hostID: pending.hostID, notificationClass: pending.kind, eventRef: pending.event)
                }
                #if DEBUG
                if launchArgument("yorozuSend") != nil {
                print("YOROZU-E2E-HOSTS \(self.hosts.sessions.count)")
                print("YOROZU-E2E-MERGED threads=\(self.hosts.threads.count) hosts=\(self.hosts.sessions.count)")
                print("YOROZU-E2E-MERGED-HOSTS \(Set(self.hosts.threads.filter { self.hosts.model(for: $0.id)?.isDraft($0.id.threadID) == false }.map { $0.id.hostID }).count)")
                }
                self.removeFirstHostForHarnessIfNeeded()
                #endif
            }
            #if DEBUG
            let onEvent = model.onEvent
            model.onEvent = { [weak model] event in
                onEvent?(event)
                if launchArgument("yorozuSend") != nil, case .message(let data) = event.payload, data.role == .agent {
                    print("YOROZU-E2E-HOST-REPLY [\(hostID)] [\(model?.title(of: event.threadId) ?? event.threadId)] \(data.text)")
                }
            }
            #endif
            hosts.add(HostSession(id: hostID, model: model, relayURL: stored.pairing.relayUrl,
                                  nickname: stored.nickname, pairedAt: stored.pairedAt))
            relays[hostID] = relay
            notificationKeys[hostID] = key
            self.model = hosts.sessions.first?.model
            if stored.paired != true { pairingHostID = hostID; isPairing = true }
            if let deviceToken { Task { await relay.registerPush(deviceToken: deviceToken) } }
            if start { model.start() }
            publishThreads()
        } catch { failure = error.localizedDescription }
    }

    #if DEBUG
    private var harnessRemoved = false
    private func removeFirstHostForHarnessIfNeeded() {
        guard !harnessRemoved, launchArgument("yorozuRemoveFirstHost") != nil,
              hosts.sessions.count > 1, hosts.sessions.allSatisfy({ $0.model.listed }),
              let first = hosts.sessions.first else { return }
        harnessRemoved = true
        Task { await removeHost(first.id) }
    }
    #endif
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = Session.shared
    /// The thread ids pushed on the list's stack: at most one, and what lets the app open a
    /// thread by itself rather than waiting to be tapped. Seeded from the session, which decided
    /// it before this view was ever built, so the first frame is already the chat.
    @State private var path: [String] = Session.shared.openPath
    @State private var hostPath: [HostThreadID] = Session.shared.hostPath
    @State private var choosingThreadHost = false
    @State private var settings = launchArgument("yorozuShowcase") == "settings"
    /// Screenshot only: `-yorozuShowcase share` draws the share extension's composer here,
    /// because a simulator cannot be made to open a real share sheet.
    @State private var shareShowcase = ChatShowcase.share
    #if DEBUG
    @State private var showcasePairingConnecting = false
    @State private var showcasePairingError: String?
    #endif

    private var actualConnection: ConnectionState {
        guard let model = session.model else { return .reconnecting }
        return ConnectionState(state: model.state, ownerOnline: model.ownerOnline)
    }

    var body: some View {
        content
            // Four things arrive as a `yorozu://` link and they are told apart by the host, not
            // by trying each parser in turn: `pair` is the pairing string tapped in Messages,
            // `thread` and `ref` name a thread to open, `share` is the share extension handing
            // over. Anything else is not ours and is ignored, not tried as a pairing code.
            .onOpenURL { url in
                switch url.host() {
                case "thread":
                    // `yorozu://thread/<id>`, so the id is the path with its leading slash off.
                    // Decoded once, by `path`: decoding again would eat a literal `%` in an id.
                    session.open(threadId: String(url.path(percentEncoded: false).dropFirst()), hostID: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "host" }?.value)
                case "ref":
                    // `yorozu://ref/<threadRef>` — a notification being tapped, which knows the
                    // thread only by the reference a push carried.
                    session.open(threadRef: String(url.path(percentEncoded: false).dropFirst()), hostID: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "host" }?.value)
                case "share":
                    // The token names the file, but everything waiting is drained either way —
                    // see ``Session/drainShares()``.
                    session.drainShares()
                case "pair":
                    session.handlePairingLink(url)
                default:
                    break
                }
            }
            // A pairing code tapped inside a chat takes the same road as one tapped in Messages.
            .environment(\.onPairingLink) { session.handlePairingLink($0) }
            .modifier(PairingConfirmation(session: session, enabled: !settings))
            .sheet(isPresented: $settings) { SettingsView(session: session) }
            // iOS suspends the app and its socket with it. Coming back is the moment to re-dial,
            // rather than waiting out a backoff that ran down while nothing was executing — and
            // the moment to pick up anything shared while it was away.
            .onChange(of: scenePhase) { _, phase in
                // Hang up before iOS suspends the app with the socket half-open: the relay
                // would go on counting a frozen socket as a phone that is watching, and so
                // not worth a silent wake-up. See ``ChatModel/suspend()``.
                if phase == .background {
                    let models = session.allModels
                    for model in models { model.suspend() }
                    let task = UIApplication.shared.beginBackgroundTask(withName: "Save offline history")
                    Task {
                        for model in models { await model.flushCache() }
                        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                    }
                }
                guard phase == .active else { return }
                // A background drain hangs up so the OS can suspend the app cleanly, so
                // coming back may be a fresh dial rather than a reconnect. `start()` does
                // nothing when a stream is already running.
                for model in session.allModels { model.start(); model.reconnect() }
                session.drainShares()
            }
            // Half of "genuinely reading": a thread on screen in an app nobody is looking at is
            // not being read, and must not report that it was. Kept apart from the switch above
            // so the reconnect only happens on an actual transition into `.active`.
            .onChange(of: scenePhase, initial: true) { _, phase in
                session.hosts.foreground = phase == .active && !settings
                if session.hosts.sessions.isEmpty { session.model?.foreground = phase == .active && !settings }
            }
            .onChange(of: settings) { _, shown in
                session.hosts.foreground = scenePhase == .active && !shown
                if session.hosts.sessions.isEmpty { session.model?.foreground = scenePhase == .active && !shown }
            }
            .onChange(of: session.hosts.sessions.map { $0.model.compatibility }) { _, _ in
                session.finishIncompatiblePairing()
            }
            // The badge counts threads, not messages: it is the same number the list's dots add
            // up to. Zero clears it rather than drawing a nought.
            .onChange(of: session.unreadCount, initial: true) { _, count in
                Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
                // Read state is the runtime's, so this fires when any device reads a thread —
                // and a notification for a thread nobody is behind on is stale on every device.
                pruneDeliveredNotifications()
            }
            // Opening the app is the moment its notifications stop being news: what is still
            // unread keeps its dot in the list, the notification centre need not repeat it.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
            }
    }

    /// Withdraws delivered notifications whose thread is no longer unread. Threads are matched by
    /// the opaque reference a push carries, so nothing here learns more than the phone already knows.
    private func pruneDeliveredNotifications() {
        let unread = Dictionary(uniqueKeysWithValues: session.hosts.sessions.map { host in
            (host.id, Set(host.model.threads.filter(\.isUnread).map { YorozuCrypto.threadRef($0.id) }))
        })
        let keys = session.notificationKeys
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let stale = delivered.compactMap { note -> String? in
                let info = note.request.content.userInfo
                guard let ref = info["ref"] as? String,
                      let verified = NotificationFallback.authenticatedPreview(userInfo: info, keys: keys),
                      let unreadRefs = unread[verified.hostID], !unreadRefs.contains(ref) else { return nil }
                return note.request.identifier
            }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if launchArgument("yorozuShowcase") == "pairing-manual" {
            PairView(onPair: { _ in String(localized: "Not a Yorozu pairing code.") })
        } else if let pairingScene = launchArgument("yorozuShowcase"), pairingScene.hasPrefix("pairing") {
            PairingFlowView(
                onPair: { _ in
                    guard pairingScene == "pairing-connection-failure" else {
                        return String(localized: "Not a Yorozu pairing code.")
                    }
                    showcasePairingError = nil
                    showcasePairingConnecting = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        showcasePairingConnecting = false
                        showcasePairingError = String(localized: "Couldn’t connect. Generate a new pairing code and try again.")
                    }
                    return nil
                },
                onDemo: {},
                externalError: pairingScene == "pairing-error"
                    ? String(localized: "Not a Yorozu pairing code.") : showcasePairingError,
                connecting: pairingScene == "pairing-connecting" || showcasePairingConnecting
            )
        } else if session.showingHosts {
            multiHostContent
        } else if let model = session.model, !session.isPairing {
            pairedContent(model)
        } else {
            pairingContent
        }
        #else
        if session.showingHosts {
            multiHostContent
        } else if let model = session.model, !session.isPairing {
            pairedContent(model)
        } else {
            pairingContent
        }
        #endif
    }

    @ViewBuilder private func pairedContent(_ model: ChatModel) -> some View {
            ThreadListView(
                threads: model.threads,
                workingThreads: model.generating,
                connection: actualConnection,
                path: $path,
                projects: model.projects,
                projectListStatus: model.projectListStatus,
                onRefreshProjects: { await model.refreshProjects() },
                onCreate: { agent, cwd in path = [model.newDraft(agent: agent, cwd: cwd).id] },
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
                    .joined(separator: "\n\n")
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
                    notificationSyncRevision: notification?.syncRevision,
                    onCreate: { agent, cwd in
                        path = [model.newDraft(agent: agent, cwd: cwd).id]
                    }
                )
            }
            .safeAreaInset(edge: .top) {
                if path.isEmpty {
                    UpdateStatusView(status: model.updateStatus) { model.updateControl(.postpone) }
                }
            }
            .overlay(alignment: .topTrailing) {
                if session.isDemo && path.isEmpty {
                    Text("Demo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: .capsule)
                        .padding(.top, 8)
                        .padding(.trailing, 72)
                        .accessibilityLabel("Demo")
                }
            }
            .sheet(isPresented: $shareShowcase) {
                ShareComposeView(
                    hosts: [ShareHost(id: "showcase", label: "My Mac")],
                    threads: model.threads.prefix(5).map { ShareThread(id: $0.id, title: $0.displayTitle, hostID: "showcase", hostLabel: "My Mac") },
                    load: { .link(URL(string: "https://cooking.example.com/roast-chicken")!) },
                    send: { _ in },
                    cancel: { shareShowcase = false }
                )
            }
            // Pairing mid-session is the other way a model appears, and it decides an opening
            // thread of its own.
            .onChange(of: session.openPath) { _, opened in path = opened }
            // Backing out discards empty drafts and keeps input. Whatever is on top is
            // the thread being read, so a reply arriving in it does not raise an unread dot.
            .onChange(of: path, initial: true) { old, new in
                if let left = old.first, !new.contains(left) { model.discardDraft(left) }
                if session.notificationOpen?.threadId != new.last { session.clearNotificationOpen() }
                model.openThread = new.last
            }
    }

    private var multiHostContent: some View {
        MultiHostThreadListView(session: session.hosts, path: $hostPath, onSettings: { settings = true }) { host, thread in
            let notification = session.notificationOpen.flatMap { $0.hostID == host.id && $0.threadId == thread.id ? $0 : nil }
            ChatView(model: host.model, thread: thread, resumeRequest: notification?.id,
                     notificationClass: notification?.notificationClass, notificationEventRef: notification?.eventRef,
                     lastReadAt: notification?.lastReadAt, notificationSyncRevision: notification?.syncRevision,
                     onNewThread: session.hosts.hasMultipleHosts ? { choosingThreadHost = true } : nil,
                     onCreate: { agent, cwd in
                         if let draft = session.hosts.newDraft(on: host.id, agent: agent, cwd: cwd) { hostPath = [draft] }
                     })
        }
        .sheet(isPresented: $choosingThreadHost) {
            NewThreadPicker(session: session.hosts) { hostPath = [$0] }
                .presentationDetents([.medium, .large])
        }
        .onChange(of: session.hostPath) { _, opened in hostPath = opened }
        .onChange(of: session.hosts.sessions.map(\.id)) { _, ids in hostPath.removeAll { !ids.contains($0.hostID) } }
        .onChange(of: hostPath, initial: true) { old, new in
            for left in old where !new.contains(left) { session.hosts.model(for: left)?.discardDraft(left.threadID) }
            for host in session.hosts.sessions { host.model.openThread = new.last.flatMap { $0.hostID == host.id ? $0.threadID : nil } }
            if let shown = new.last { session.rememberHost(shown.hostID) }
            if let notification = session.notificationOpen,
               new.last != HostThreadID(hostID: notification.hostID, threadID: notification.threadId) { session.clearNotificationOpen() }
        }
        .onChange(of: session.hosts.lastUsedHostID) { _, id in
            if let id { session.rememberHost(id) }
        }
        .onChange(of: session.hosts.sessions.map(\.label)) { _, _ in session.publishThreads() }
    }

    private var pairingContent: some View {
        PairingFlowView(
            onPair: pair,
            onDemo: session.startDemo,
            externalError: session.pairingFailure ?? session.model?.failure.map { _ in
                String(localized: "Couldn’t connect. Generate a new pairing code and try again.")
            },
            connecting: session.isPairing && session.pairingFailure == nil
        )
    }

    /// Returns the message the pairing screens show, or nil when the code was good.
    private func pair(with text: String) -> String? {
        do {
            try session.pair(with: text)
            return nil
        } catch {
            if session.pendingPairing != nil { return nil }
            return (error as? Session.PairingFailure)?.errorDescription ?? String(localized: "Not a Yorozu pairing code.")
        }
    }
}

/// Shared by the root and the presented Add Host flow, so links and duplicate scans ask alike.
struct PairingConfirmation: ViewModifier {
    let session: Session
    var enabled = true

    func body(content: Content) -> some View {
        content.alert(session.pendingPairing?.existingHostID == nil ? "Add host?" : "Already connected",
            isPresented: Binding(get: { enabled && session.pendingPairing != nil },
                                 set: { if !$0 && enabled { session.cancelPendingPairing() } }),
            presenting: session.pendingPairing) { pending in
                Button(pending.existingHostID == nil ? "Add host" : "Repair connection") {
                    Task { await session.confirmPairing(pending) }
                }
                Button("Cancel", role: .cancel) { session.cancelPendingPairing() }
            } message: { pending in
                Text(pending.existingHostID == nil
                    ? "Add this Mac to Yorozu?\n\nRelay: \(pending.relayHost)\nMac key: \(pending.macKeyFingerprint)"
                    : "This Mac is already paired. Repair replaces only its connection.\n\nRelay: \(pending.relayHost)\nMac key: \(pending.macKeyFingerprint)")
            }
    }
}
