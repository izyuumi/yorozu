// scripts/check-mac-multi-host.sh compiles this with the ACTUAL MacChatSession.swift.
// Only external effects are replaced: network, Keychain, sidecar, and consent/update UI.
import AppKit
import CryptoKit
import Foundation
import SwiftUI
import YorozuShared

@MainActor final class Sidecar {
    static let shared = Sidecar()
    func start() { fatalError("The client harness must never start a sidecar") }
    func stop() {}
}
enum OnboardingWindow { static let completedKey = "unused-multi-host-check-onboarding" }
@MainActor enum PairingConsent { static func ask(_ pairing: MacChatSession.PendingPairing) -> Bool { false } }
@MainActor enum YoloConsent { static func ask(_ request: ApprovalSettingsRequestData, model: ChatModel) {} }
@MainActor struct Updates {
    static let pending = Updates()
    func receive(_ status: UpdateStatusData, from model: ChatModel) {}
}
enum Log { static func write(_ message: String) { print(message) } }

// UI hosting support normally supplied by GeneralSettings.swift, outside this session harness.
extension View {
    func leadingFooter() -> some View {
        multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func check(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(description: message) }
}
@MainActor private func eventually(_ message: String, _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CheckFailure(description: "Timed out: " + message) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private final class MemoryVault: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    private var writes = 0
    private var shouldFailWrites = false
    var failCollectionWrites: Bool {
        get { lock.withLock { shouldFailWrites } }
        set { lock.withLock { shouldFailWrites = newValue } }
    }
    func read(_ key: String) -> Data? { lock.withLock { data[key] } }
    func write(_ value: Data, _ key: String) throws {
        try lock.withLock {
            if shouldFailWrites && key == "pairings-v2" { throw CheckFailure(description: "Injected Keychain failure") }
            data[key] = value
            writes += 1
        }
    }
    func erase(_ key: String) { lock.withLock { _ = data.removeValue(forKey: key) } }
    var writeCount: Int { lock.withLock { writes } }
}

private actor FakeTransport: ChatTransport {
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    private(set) var sent: [YorozuEvent] = []
    private(set) var closed = false
    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        continuation.yield(.state(.paired))
        continuation.yield(.ownerOnline(true))
        return stream
    }
    func send(_ event: YorozuEvent) {
        sent.append(event)
        updates?.yield(.event(YorozuEvent(id: "receipt-" + event.id, threadId: event.threadId, ts: event.ts,
            agentId: "host", payload: .receipt(ReceiptData(eventId: event.id)))))
    }
    func close() { closed = true; updates?.finish() }
    func deliver(_ update: TransportUpdate) { updates?.yield(update) }
    func messages() -> [String] {
        sent.compactMap { if case .message(let data) = $0.payload { data.text } else { nil } }
    }
}

@MainActor private final class Connections {
    private(set) var transports: [HostID: [FakeTransport]] = [:]
    func model(_ stored: MacPairingStore.Stored, store: MacPairingStore) throws -> ChatModel {
        let transport = FakeTransport()
        transports[stored.id, default: []].append(transport)
        return ChatModel(transport: transport, cache: try store.openCache(for: stored), device: "mac")
    }
    func latest(_ id: HostID) -> FakeTransport { transports[id]!.last! }
    var count: Int { transports.values.reduce(0) { $0 + $1.count } }
}

private struct Fixture {
    let directory = URL.temporaryDirectory.appending(path: "yorozu-multi-host-" + UUID().uuidString)
    let suite = "yorozu-multi-host-" + UUID().uuidString
    let vault = MemoryVault()
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    func store() -> MacPairingStore {
        MacPairingStore(directory: directory, defaults: defaults,
            read: { vault.read($0) }, write: { try vault.write($0, $1) }, erase: { vault.erase($0) })
    }
    func clean() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

private func pairing(_ name: String) -> QrPayload {
    QrPayload(relayUrl: "wss://\(name).example.test",
        macPubkey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLEncodedString(),
        token: Data(UUID().uuidString.utf8).base64URLEncodedString(), roomId: name)
}
private func event(_ id: String, thread: String = "same", payload: YorozuEvent.Payload) -> YorozuEvent {
    YorozuEvent(id: id, threadId: thread, ts: 100, agentId: "host", payload: payload)
}

@main struct MacMultiHostCheck {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await sessionBehavior()
        try legacyMigration(fallback: false)
        try legacyMigration(fallback: true)
        print("PASS Mac multi-host: pairing, merged search, routed sends, repair/removal isolation and rollback, legacy cache/counter migration")
    }

    @MainActor private static func sessionBehavior() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let store = fixture.store()
        let connections = Connections()
        let session = MacChatSession(store: store, initialRole: .client,
            clientFactory: { try connections.model($0, store: store) })
        let invalid = QrPayload(relayUrl: "wss://invalid.example.test", macPubkey: "short", token: "token")
        do {
            try session.pair(with: invalid.encoded())
            throw CheckFailure(description: "Invalid host key was accepted")
        } catch let error as CheckFailure { throw error }
        catch {}
        try check(fixture.vault.writeCount == 0 && connections.count == 0, "Invalid key must fail before identity storage or connection")
        let alpha = pairing("alpha"), beta = pairing("beta")
        let alphaID = alpha.hostID!, betaID = beta.hostID!
        let alphaRef = HostThreadID(hostID: alphaID, threadID: "same")
        let betaRef = HostThreadID(hostID: betaID, threadID: "same")
        let alphaCode = try alpha.encoded()
        try check(session.pairingLinkAction(for: URL(string: alphaCode)!) == .pair(alphaCode),
            "First pairing link may enter normal pairing flow")
        try session.pair(with: alpha.encoded())
        try session.pair(with: beta.encoded())
        try check(session.failure == nil && session.hosts.sessions.count == 2, "Pairing two hosts must keep both sessions")
        let modelA = session.hosts.model(for: alphaRef)!, modelB = session.hosts.model(for: betaRef)!
        let transportA = connections.latest(alphaID), transportB = connections.latest(betaID)
        try await eventually("both hosts online") { modelA.canDeliver && modelB.canDeliver }
        await transportA.deliver(.event(event("list", thread: "", payload: .threadList(ThreadListData(threads: [
            ThreadSummary(id: "same", title: "Alpha thread", archived: false, lastActivity: 100),
        ])))))
        await transportB.deliver(.event(event("list", thread: "", payload: .threadList(ThreadListData(threads: [
            ThreadSummary(id: "same", title: "Beta thread", archived: false, lastActivity: 200),
        ])))))
        await transportA.deliver(.event(event("same-message", payload: .message(MessageData(role: .agent, text: "cobalt-only", done: true)))))
        await transportB.deliver(.event(event("same-message", payload: .message(MessageData(role: .agent, text: "ochre-only", done: true)))))
        try await eventually("colliding threads and messages received") {
            session.hosts.threads.count == 2 && session.hosts.messageText(for: alphaRef) == "cobalt-only"
                && session.hosts.messageText(for: betaRef) == "ochre-only"
        }
        try check(session.hosts.threads.map(\.id) == [betaRef, alphaRef], "Merged threads must sort across hosts by activity")
        try check(session.hosts.search("thread").threads.count == 2, "Metadata search must preserve colliding thread IDs")
        try check(session.hosts.search("cobalt").messages.map(\.id) == [alphaRef], "Message search must route to alpha")
        try check(session.hosts.search("ochre").messages.map(\.id) == [betaRef], "Message search must route to beta")
        session.hosts.model(for: alphaRef)!.send("alpha-send", in: alphaRef.threadID)
        session.hosts.model(for: betaRef)!.send("beta-send", in: betaRef.threadID)
        try await eventually("routed messages") {
            let a = await transportA.messages(), b = await transportB.messages()
            return a == ["alpha-send"] && b == ["beta-send"]
        }
        try await eventually("initial sends acknowledged") { modelA.outbox.isEmpty && modelB.outbox.isEmpty }

        session.nickname("Alpha computer", for: alphaID)
        session.nickname("Beta computer", for: betaID)
        if let argument = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.count > argument + 1 {
            await transportB.deliver(.ownerOnline(false))
            try await eventually("screenshot offline state") { !modelB.canDeliver }
            try await screenshot(session, path: CommandLine.arguments[argument + 1])
            await transportB.deliver(.ownerOnline(true))
            try await eventually("beta online after screenshot") { modelB.canDeliver }
        }
        let original = try store.loadAll()
        let storedA = original.first { $0.id == alphaID }!, storedB = original.first { $0.id == betaID }!
        let counterA = MacPairingCounterStorage(store: store, host: storedA)
        let counterB = MacPairingCounterStorage(store: store, host: storedB)
        try counterA.save(ChannelCounter(send: 21, recv: 34))
        try counterB.save(ChannelCounter(send: 55, recv: 89))
        await modelA.flushCache(); await modelB.flushCache()
        let alphaKey = fixture.vault.read("thread-cache-key-" + alphaID)
        let betaKey = fixture.vault.read("thread-cache-key-" + betaID)
        var replacement = alpha
        replacement.token = "fresh-token"
        replacement.relayUrl = "wss://moved-alpha.example.test"
        replacement.roomId = "new-alpha-room"
        let beforeDuplicate = fixture.vault.read("pairings-v2"), beforeWrites = fixture.vault.writeCount
        let replacementCode = try replacement.encoded(), thirdHost = pairing("unpaired")
        guard case .confirm(let repairPrompt) = session.pairingLinkAction(for: URL(string: replacementCode)!) else {
            throw CheckFailure(description: "Duplicate pairing link must request repair consent")
        }
        try check(repairPrompt.repairsHost == alphaID && !repairPrompt.stopsHosting && repairPrompt.code == replacementCode,
            "Duplicate link consent must identify only its paired host")
        guard case .confirm(let addPrompt) = session.pairingLinkAction(for: URL(string: try thirdHost.encoded())!) else {
            throw CheckFailure(description: "Additional pairing link must request add-host consent")
        }
        try check(addPrompt.repairsHost == nil && !addPrompt.stopsHosting, "Additional link must not repair another host")
        do {
            try await session.repair(with: thirdHost.encoded())
            throw CheckFailure(description: "Repair unexpectedly added an unpaired host")
        } catch MacChatSession.PairingError.unknownHost {}
        do {
            try session.pair(with: replacement.encoded())
            throw CheckFailure(description: "Duplicate host was accepted")
        } catch MacChatSession.PairingError.alreadyConnected {}
        try check(connections.count == 2, "Duplicate must not create a transport or consume its code")
        try check(fixture.vault.writeCount == beforeWrites && fixture.vault.read("pairings-v2") == beforeDuplicate,
            "Duplicate must not replace identities or counters")
        try check(session.hosts.model(for: alphaRef) === modelA, "Duplicate must preserve existing model")

        fixture.vault.failCollectionWrites = true
        do {
            try await session.repair(with: replacement.encoded())
            throw CheckFailure(description: "Repair ignored failed registry write")
        } catch let error as CheckFailure where error.description == "Injected Keychain failure" {}
        fixture.vault.failCollectionWrites = false
        let rolledBackA = try store.loadAll().first { $0.id == alphaID }!
        try check(rolledBackA.identity == storedA.identity && rolledBackA.counters == ChannelCounter(send: 21, recv: 34),
            "Failed repair must preserve old identity and counters")
        let restoredModel = session.hosts.model(for: alphaRef)!
        try check(restoredModel !== modelA && restoredModel.threads.first?.title == "Alpha thread",
            "Failed repair must restore a usable model with original cache")
        try await eventually("original connection restored after failed repair") { restoredModel.canDeliver }
        let restoredTransport = connections.latest(alphaID)
        await restoredTransport.deliver(.ownerOnline(false))
        try await eventually("alpha offline before repair") { !restoredModel.canDeliver }
        restoredModel.send("alpha-pending", in: "same")
        restoredModel.drafts["same"] = "Unsent alpha draft"
        try await session.repair(with: replacement.encoded())
        let repairedA = try store.loadAll().first { $0.id == alphaID }!
        let replacementModel = session.hosts.model(for: alphaRef)!
        try await eventually("repaired host online") { replacementModel.canDeliver }
        try check(await transportA.closed, "Repair must close old transport")
        try check(repairedA.identity != storedA.identity && repairedA.counters == nil, "Repair must rotate target identity and counters")
        try check(repairedA.pairing == replacement && repairedA.nickname == "Alpha computer", "Repair must replace code and preserve nickname")
        try check(replacementModel !== restoredModel && replacementModel.threads.first?.title == "Alpha thread",
            "Repair must preserve target cached threads")
        try check(session.hosts.messageText(for: alphaRef).contains("cobalt-only") && replacementModel.drafts["same"] == "Unsent alpha draft",
            "Repair must preserve target history and newest unsent draft")
        try check(fixture.vault.read("thread-cache-key-" + alphaID) == alphaKey, "Repair must preserve target cache key")
        let replacementTransport = connections.latest(alphaID)
        try await eventually("repair preserves pending send") { await replacementTransport.messages() == ["alpha-pending"] }
        try check(await restoredTransport.closed, "Repair must retire restored old transport before reconnecting")
        try check(session.hosts.model(for: betaRef) === modelB, "Repair must preserve other host model")
        try check(try counterB.load() == ChannelCounter(send: 55, recv: 89), "Repair must preserve other host counters")
        try check(fixture.vault.read("thread-cache-key-" + betaID) == betaKey, "Repair must preserve other host cache key")
        do {
            try counterA.save(ChannelCounter(send: 999, recv: 999))
            throw CheckFailure(description: "Retired identity overwrote replacement counters")
        } catch is MacPairingCounterStorage.NoPairing {}

        // Leave a queued message on beta while alpha is removed. It must survive and send
        // through beta once beta returns, even though its raw thread ID equals alpha's.
        await transportB.deliver(.ownerOnline(false))
        try await eventually("beta offline") { !modelB.canDeliver }
        modelB.send("beta-queued", in: "same")
        await modelB.flushCache()
        let betaCache = try store.openCache(for: storedB)
        let betaEvents = betaCache.events(threadId: "same")
        try check(betaEvents.contains { if case .message(let data) = $0.payload { data.text == "beta-queued" } else { false } },
            "Offline beta message must be cached")
        fixture.vault.failCollectionWrites = true
        await session.removeHost(alphaID)
        fixture.vault.failCollectionWrites = false
        try check(session.failure != nil, "Failed remove must report registry error")
        let afterFailedRemove = try store.loadAll()
        try check(afterFailedRemove.count == 2 && afterFailedRemove.first { $0.id == alphaID }?.identity == repairedA.identity,
            "Failed remove must preserve committed alpha identity")
        let resumedAfterRemove = session.hosts.model(for: alphaRef)!
        try check(resumedAfterRemove !== replacementModel, "Failed remove must rebuild retired target model")
        try await eventually("failed removal restores usable connection") { resumedAfterRemove.canDeliver }
        try check(session.hosts.model(for: betaRef) === modelB && betaCache.events(threadId: "same") == betaEvents,
            "Failed remove must preserve beta model and queue")
        let removedTransport = connections.latest(alphaID)
        await session.removeHost(alphaID)
        try check(session.failure == nil && session.hosts.sessions.map(\.id) == [betaID], "Remove must leave only beta connected")
        let remaining = try store.loadAll()
        try check(remaining.count == 1 && remaining[0].identity == storedB.identity, "Remove must preserve beta registry and identity")
        try check(try counterB.load() == ChannelCounter(send: 55, recv: 89), "Remove must preserve beta counters")
        try check(betaCache.events(threadId: "same") == betaEvents, "Remove must preserve beta encrypted cache")
        try check(fixture.vault.read("thread-cache-key-" + alphaID) == nil, "Remove must delete alpha cache key")
        try check(fixture.vault.read("thread-cache-key-" + betaID) == betaKey, "Remove must preserve beta cache key")
        try check(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "client-hosts").appending(path: alphaID).path),
            "Removed cache must stay deleted after shutdown")
        try check(await replacementTransport.closed, "Remove must close target transport")
        try check(await removedTransport.closed, "Retried remove must close rebuilt target transport")
        try check(!(await transportB.closed), "Remove must keep beta transport open")
        await transportB.deliver(.ownerOnline(true))
        try await eventually("beta queued send") { await transportB.messages() == ["beta-send", "beta-queued"] }
        try check(await replacementTransport.messages() == ["alpha-pending"], "Beta queue must never reach removed alpha")
        await modelB.shutdown()
    }

    @MainActor private static func screenshot(_ session: MacChatSession, path: String) async throws {
        func content(height: CGFloat) -> some View {
            HostsView(session: session).padding(24).frame(width: 640, height: height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        }
        let view = NSHostingView(rootView: content(height: 420))
        view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        try capture(view, path: path)
        view.rootView = content(height: 680)
        window.setContentSize(NSSize(width: 640, height: 680))
        try await Task.sleep(for: .milliseconds(100))
        // Fixture-only disclosure control, measured from this window's fixed layout. It
        // expands beta's offline details; never touches consent or destructive controls.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = NSEvent.mouseEvent(with: type, location: NSPoint(x: 39, y: 571),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(click)
        }
        try await Task.sleep(for: .seconds(1))
        let detailsPath = URL(fileURLWithPath: path).deletingPathExtension().path + "-details.png"
        try capture(view, path: detailsPath)
        window.close()
    }

    @MainActor private static func capture(_ view: NSView, path: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CheckFailure(description: "Could not create HostsView screenshot")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "Could not encode HostsView screenshot")
        }
        try image.write(to: URL(fileURLWithPath: path))
        print("SCREEN \(path)")
    }

    // Encode the pre-collection schema independently of the new Stored type. Its optional
    // counters match real old records; old fallback counters live in UserDefaults.
    private struct LegacyStored: Encodable {
        let pairing: QrPayload
        let identity: PhoneIdentity
        let paired: Bool
        let pairedAt: Date
        let counters: ChannelCounter?
    }
    private static func legacyMigration(fallback: Bool) throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let store = fixture.store()
        var payload = pairing(fallback ? "legacy-fallback" : "legacy-record")
        payload.token = ""
        let identity = PhoneIdentity.generate(), counters = ChannelCounter(send: 144, recv: 233)
        let pairedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = LegacyStored(pairing: payload, identity: identity, paired: true, pairedAt: pairedAt,
            counters: fallback ? nil : counters)
        let legacyBytes = try JSONEncoder().encode(legacy)
        try fixture.vault.write(legacyBytes, "pairing")
        let fallbackStore = ChannelCounterStore(defaults: fixture.defaults, ownPub: identity.sessionPublicKey,
            peerPub: Data(base64URLEncoded: payload.macPubkey)!)
        if fallback { try fallbackStore.save(counters) }
        let key = SymmetricKey(size: .bits256), keyBytes = key.withUnsafeBytes { Data($0) }
        try fixture.vault.write(keyBytes, "thread-cache-key")
        let oldCache = ThreadCache(directory: fixture.directory.appending(path: "client-threads"), key: key)
        let thread = ThreadSummary(id: "legacy-thread", title: "Preserved history", archived: false, lastActivity: 123)
        let message = event("legacy-message", thread: thread.id, payload: .message(MessageData(role: .agent, text: "legacy private history", done: true)))
        oldCache.save(threads: [thread]); oldCache.save(events: [message], threadId: thread.id, lastSeen: message.id)
        let encryptedBytes = try Data(contentsOf: oldCache.directory.appending(path: "threads.bin"))
        if fallback {
            fixture.vault.failCollectionWrites = true
            do {
                _ = try store.loadAll()
                throw CheckFailure(description: "Migration ignored failed persistence")
            } catch let error as CheckFailure where error.description == "Injected Keychain failure" {}
            try check(fixture.vault.read("pairing") == legacyBytes && fixture.vault.read("pairings-v2") == nil,
                "Failed migration must retain legacy identity")
            try check(try fallbackStore.load() == counters, "Failed migration must retain fallback counters")
            fixture.vault.failCollectionWrites = false
        }
        let migrated = try store.loadAll()
        try check(migrated.count == 1, "Legacy pairing must migrate exactly once")
        let host = migrated[0]
        try check(host.id == payload.hostID && host.identity == identity && host.pairedAt == pairedAt && host.paired == true,
            "Migration must preserve host identity and paired timestamp")
        try check(host.counters == counters, "Migration must retain nonzero counters")
        try check(fixture.vault.read("pairing") == nil && fixture.vault.read("pairings-v2") != nil, "Migration must commit collection before retiring legacy record")
        try check(try fallbackStore.load() == nil, "Migration must retire committed fallback counters")
        let cache = try store.openCache(for: host)
        try check(cache.threads() == [thread] && cache.events(threadId: thread.id) == [message], "Migration must retain decryptable history")
        try check(cache.lastSeen()[thread.id] == message.id, "Migration must retain replay cursor")
        try check(cache.directory == oldCache.directory && fixture.vault.read("thread-cache-key") == keyBytes,
            "Migration must retain legacy cache location and key")
        try check(try Data(contentsOf: cache.directory.appending(path: "threads.bin")) == encryptedBytes,
            "Migration must not rewrite encrypted cache")
        let reopened = fixture.store()
        try check(try reopened.loadAll().count == 1, "Repeated load must not duplicate migration")
        try check(try MacPairingCounterStorage(store: reopened, host: host).load() == counters,
            "Restart must reload migrated counters")
    }
}
