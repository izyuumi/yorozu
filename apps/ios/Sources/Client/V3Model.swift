import Foundation
import Observation
import UserNotifications
import YorozuWire
#if os(macOS)
import AppKit
#endif

/// The v3 client (#425): one pairing with the OpenClaw plugin, the conversations cached on this device, and the link.
/// User messages without `delivered` are the outbox: each new session sends them again, and the plugin drops a
/// `messageId` it already took. History (#427): each new session asks for `conv_list` and fetches what is newer
/// than the cache; opening a conversation fills its gap, scrolling up loads older pages. One request is in flight at a
/// time, so pages reach the relay paced.
@MainActor @Observable
final class V3Model {
    private(set) var pairing: V3Pairing?
    private(set) var state = V3Connection.State.offline
    private(set) var conversations: [String: Conversation] = [:]
    /// Conversations whose agent is working: from `run_started` or `typing {active}` until `typing {active: false}`,
    /// or 30 s without a repeat.
    private(set) var typing: Set<String> = []
    /// Conversations waiting for an older `history` page: the chat's top spinner.
    private(set) var loadingOlder: Set<String> = []
    /// A scanned or pasted code waiting for the user to compare the host fingerprint.
    var pendingPairing: QrPayload?
    /// Why the last pairing attempt failed, for the pairing screen.
    var pairingError: String?
    /// A tapped notification's conversation, for the list to open (#431).
    var requestedConversation: String?
    /// The conversation on screen while the app is active: told to the plugin, which sends no push for it here (#431).
    private(set) var foreground: String?
    /// The Crons tab (#432): the configured agent's jobs as the plugin last sent them, nil before the first answer.
    private(set) var crons: [V3CronJob]?
    /// Why the plugin could not list them, from its last answer.
    private(set) var cronsError: String?
    /// An automation waiting in a conversation's composer as an attachment ("Edit in Chat"); the chat takes it once.
    var automationDrafts: [String: V3CronJob] = [:]
    /// Settings: the paired devices as the plugin last listed them, nil before its first answer.
    private(set) var devices: [V3DeviceInfo]?
    /// Why the plugin could not list or change them, from its last answer.
    private(set) var devicesError: String?
    /// The host's answer to ``requestInvite()``: a one-time code for another device, or its error. Nil while asking.
    private(set) var invite: V3PairInvite?
    /// The in-app notice for a reply in another conversation while the app is active; the newest replaces it.
    var notice: V3InAppNotice?

    @ObservationIgnored private var connection: V3Connection?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var typingTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let cache = ConversationCache()
    /// `conv_list` and `history` requests waiting for the one in flight.
    @ObservationIgnored private var requests: [V3Event] = []
    @ObservationIgnored private var inFlight: V3Event?
    @ObservationIgnored private var inFlightTimer: Task<Void, Never>?
    /// Cursors the plugin sent for conversations not cached here yet; applied when one arrives. The plugin sends them
    /// again on every session, so they need no disk.
    @ObservationIgnored private var unplacedReads: [String: V3ReadCursor] = [:]
    @ObservationIgnored private var badge: Int?
    /// The plugin's `peer_info` on the live session: its capabilities and attachment limit.
    private(set) var hostInfo: V3PeerInfo?
    /// Attachment transfers over the live session (#430).
    let transfers = V3Transfers()
    @ObservationIgnored private var outboxPumping = false
    @ObservationIgnored private var outboxAgain = false
    @ObservationIgnored private var outboxResend = false
    @ObservationIgnored private var visible: String?
    @ObservationIgnored private(set) var active = false
    /// The `active` flag the plugin last heard, with ``foreground``.
    @ObservationIgnored private var activeSent = false
    /// The APNs token, lowercase hex, for every connection (#431).
    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private var cronWaiters: [CheckedContinuation<Void, Never>] = []

    static let typingTimeout: Duration = .seconds(30)
    /// No answer within this: the request is dropped and the next one goes (the session may have died meanwhile).
    static let requestTimeout: Duration = .seconds(30)

    init() {
        transfers.send = { [weak self] event in
            guard let connection = self?.connection else { return false }
            return await connection.send(event)
        }
        do {
            pairing = try V3Pairing.load()
        } catch {
            pairingError = String(localized: "Couldn’t read this device’s pairing: \(error.localizedDescription)")
        }
        guard pairing != nil else { return }
        for conversation in cache.loadAll() { conversations[conversation.id] = conversation }
        updateBadge()
        connect()
        takeShares()
    }

    /// Paired, or pairing for the first time.
    var paired: Bool { pairing?.paired == true }
    var connecting: Bool { pairing != nil && !paired }

    /// Newest first, archived ones left out.
    var list: [Conversation] { sorted.filter { $0.archived != true } }

    /// The Archived view (#428), newest first.
    var archivedList: [Conversation] { sorted.filter { $0.archived == true } }

    private var sorted: [Conversation] {
        conversations.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    var fingerprint: String? { pairing?.pairing.fingerprint }

    // MARK: Pairing

    /// A QR, a pasted string or a tapped link. Returns why it is not a v3 pairing code; otherwise it waits in
    /// ``pendingPairing`` for the fingerprint check.
    func submit(_ text: String) -> String? {
        guard let payload = try? QrPayload.decode(text), payload.v == 3, payload.roomId != nil, payload.secret != nil,
              (Data(base64URLEncoded: payload.macPubkey)?.count ?? 0) == 32 else {
            return String(localized: "This isn’t a Yorozu pairing code. Run `openclaw yorozu pair` on the host and use the code it prints.")
        }
        pairingError = nil
        pendingPairing = payload
        return nil
    }

    /// The user compared the fingerprint: a fresh identity, kept in the Keychain before the first join.
    func confirm(_ payload: QrPayload) {
        pendingPairing = nil
        disconnect()
        cache.wipe()
        AttachmentFiles.wipe()
        conversations = [:]
        let new = V3Pairing(pairing: payload, identity: .generate())
        do {
            try new.save()
        } catch {
            pairingError = String(localized: "Couldn’t save the pairing: \(error.localizedDescription)")
            return
        }
        pairing = new
        connect()
    }

    /// Forgets the host on this device: keys and cache. The plugin keeps the device until `openclaw yorozu devices remove`.
    func unpair() {
        disconnect()
        try? V3Pairing.remove()
        #if os(iOS)
        PreviewKeychain.clear()
        #endif
        cache.wipe()
        AttachmentFiles.wipe()
        ShareInbox.clear()
        pairing = nil
        conversations = [:]
        typing = []
        unplacedReads = [:]
        updateBadge()
        crons = nil
        cronsError = nil
        devices = nil
        devicesError = nil
        notice = nil
    }

    // MARK: Link

    private func connect() {
        guard let pairing else { return }
        let local = V3PeerInfo(app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            name: DeviceModel.name, capabilities: [V3Attachment.capability, V3Devices.capability])
        guard let connection = try? V3Connection(pairing: pairing.pairing, identity: pairing.identity,
            relayKnows: pairing.relayKnows, local: local) else {
            return failPairing(String(localized: "This pairing code can’t be used."))
        }
        self.connection = connection
        #if os(iOS)
        // The notification service extension opens push previews with this key, readable after the first unlock.
        if let hostKey = Data(base64URLEncoded: pairing.pairing.macPubkey),
           let key = try? PushPreview.key(myPriv: pairing.identity.sessionPrivateKey, theirPub: hostKey) {
            PreviewKeychain.save(key)
        }
        #endif
        let pushToken = pushToken
        listener = Task { [weak self] in
            let updates = await connection.updates()
            if let pushToken { await connection.registerPush(deviceToken: pushToken) }
            await connection.start()
            for await update in updates { self?.apply(update) }
        }
    }

    private func disconnect() {
        listener?.cancel()
        listener = nil
        if let connection { Task { await connection.stop() } }
        connection = nil
        state = .offline
    }

    /// Back in the foreground: dial now. iOS may have left the socket half open.
    func resume() {
        setActive(true)
        takeShares()
        guard let connection else { return connect() }
        Task { await connection.reconnect() }
    }

    /// iOS suspends a background app: hang up, so the relay does not hold a frozen socket. The plugin hears first that
    /// no conversation is on screen any more, or it would hold this device's pushes back (#431).
    func suspend() {
        setActive(false)
        guard let connection else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !active else { return }
            await connection.stop()
        }
    }

    // MARK: Push (#431)

    /// The app is active or not; with the chat on screen it decides ``foreground``.
    func setActive(_ active: Bool) {
        self.active = active
        updateForeground()
    }

    /// A chat view appeared (`convId`), or went (nil, `leaving` the one it showed).
    func setVisible(_ convId: String?, leaving: String? = nil) {
        if convId == nil, let leaving, visible != leaving { return }
        visible = convId
        updateForeground()
        if let convId { V3Notices.removeDelivered(convId: convId) }
    }

    /// The plugin hears the conversation on screen and whether the app is in front at all: no push while it is, the
    /// in-app notice instead.
    private func updateForeground() {
        let next = active ? visible : nil
        guard next != foreground || active != activeSent else { return }
        foreground = next
        activeSent = active
        transmit(.foreground(V3Foreground(convId: next, active: active)))
    }

    /// Woken by a silent push (a conversation read elsewhere, or a reply): connect long enough for the plugin's read
    /// cursors, which clear the notifications of what was read, then hang up again unless the app came to the front.
    func backgroundWake() async {
        guard paired, !active else { return }
        if let connection { await connection.reconnect() } else { connect() }
        for _ in 0..<40 where state != .ready { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .seconds(2))
        guard !active, let connection else { return }
        await connection.stop()
    }

    /// A reply in a conversation not on screen while the app is in front: one notice at the top, replacing another
    /// conversation's. One already showing for this conversation stays, so a reply in several chunks taps once.
    private func showNotice(convId: String, title: String, text: String) {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line, notice?.convId != convId else { return }
        notice = V3InAppNotice(convId: convId, title: title.isEmpty ? String(localized: "Yorozu replied.") : title, text: line)
    }

    /// A push that arrived while the app is in front (sent before the plugin heard it was): shown as the notice.
    func showNotice(for convId: String, title: String, body: String) {
        guard convId != foreground else { return }
        showNotice(convId: convId, title: title, text: body)
    }

    /// The APNs token: kept for every connection, told to the relay now.
    func registerPush(_ token: String) {
        pushToken = token
        guard let connection else { return }
        Task { await connection.registerPush(deviceToken: token) }
    }

    /// The conversation a notification is about: the sealed preview's `convId` (copied by the notification service
    /// extension, or set by the Mac's local notice), else the relay's `ref` matched against the cached conversations.
    func conversation(convId: String?, ref: String?) -> String? {
        if let convId, V3Event.isId(convId) { return convId }
        guard let ref else { return nil }
        return conversations.keys.first { YorozuCrypto.threadRef($0) == ref }
    }

    /// Alerts, sounds and the badge, asked once paired; the system asks the user only the first time.
    func requestNotifications() {
        guard paired else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            // A badge set before the user allowed it did not show.
            badge = nil
            updateBadge()
        }
    }

    private func apply(_ update: V3Connection.Update) {
        switch update {
        case .state(let new):
            state = new
            if new != .ready { transfers.sessionLost() }
            switch new {
            case .pairingFailed:
                if !paired { failPairing(String(localized: "The host refused this pairing code. It may have expired or been used. Run `openclaw yorozu pair` again.")) }
            case .unpaired:
                if !paired { failPairing(String(localized: "The host doesn’t know this device. Run `openclaw yorozu pair` again.")) }
            case .ready, .offline, .connecting, .hostOffline, .handshaking, .updateRequired:
                break
            }
        case .relayJoined:
            updatePairing { $0.relayKnows = true; $0.pairing.token = "" }
        case .sessionOpen(let host):
            hostInfo = host
            if !paired { updatePairing { $0.paired = true; $0.pairedAt = Date(); $0.pairing.secret = nil } }
            requestNotifications()
            publishShareDirectory()
            takeShares()
            pumpOutbox(resend: true)
            transfers.resumeDownloads()
            // A new session starts with nothing on screen, as far as the plugin knows.
            if active { transmit(.foreground(V3Foreground(convId: foreground, active: true))) }
            startSync()
            for conversation in conversations.values where conversation.readPending == true {
                if let cursor = conversation.read { transmit(.readCursor(cursor)) }
            }
        case .accepted(let id):
            mark(id, .sent)
        case .event(let event):
            receive(event)
        }
    }

    private func failPairing(_ message: String) {
        unpair()
        pairingError = message
    }

    private func updatePairing(_ change: (inout V3Pairing) -> Void) {
        guard var pairing else { return }
        change(&pairing)
        self.pairing = pairing
        try? pairing.save()
    }

    // MARK: Messages

    /// A new message in `convId`; a conversation that does not exist yet starts with it ("+" makes the id).
    /// `attachments` are already in `AttachmentFiles` (`AttachmentStaging`); they upload before the message goes.
    func send(_ text: String, attachments: [ChatAttachment] = [], in convId: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, V3Event.isId(convId) else { return }
        let item = ChatItem(id: V3Event.newId(), kind: .user, text: text, ts: Self.now, status: .queued,
            attachments: attachments.isEmpty ? nil : attachments)
        append(item, to: convId)
        pumpOutbox(resend: false)
    }

    /// The host takes attachments: it said so, or has not said yet (an old plugin's `peer_info` lacks the capability).
    var attachmentsAvailable: Bool { hostInfo.map { $0.capabilities.contains(V3Attachment.capability) } ?? true }
    /// The host's attachment limit (`mediaMaxMb`).
    var mediaMaxBytes: Int { hostInfo?.mediaMaxBytes ?? V3Attachment.defaultMaxBytes }

    /// Sends the outbox in order on the live session: each message's files upload first, then the message. A new
    /// session (`resend`) also sends again what went out without `delivered`; otherwise only what has not gone yet.
    /// One pass at a time; a pass cut by a lost session ends, and the next session's pass starts its upload over.
    private func pumpOutbox(resend: Bool) {
        if resend { outboxResend = true }
        outboxAgain = true
        guard !outboxPumping else { return }
        outboxPumping = true
        Task {
            while outboxAgain {
                outboxAgain = false
                let all = outboxResend
                outboxResend = false
                guard await sendOutbox(all: all) else { break }
            }
            outboxPumping = false
        }
    }

    /// False when the session went mid-way.
    private func sendOutbox(all: Bool) async -> Bool {
        let pending = conversations.values.flatMap { conversation in
            conversation.items.filter { item in
                guard item.kind == .user, let status = item.status, all ? status < .delivered : status == .queued else { return false }
                return !item.text.isEmpty || item.attachments?.contains { $0.failure == nil } == true
            }.map { (conversation.id, $0) }
        }
        for (convId, queued) in pending.sorted(by: { $0.1.ts < $1.1.ts }) {
            guard let connection, state == .ready else { return false }
            for attachment in queued.attachments ?? [] where attachment.uploaded != true && attachment.failure == nil {
                switch await transfers.upload(attachment) {
                case .stored: updateAttachment(attachment.id, of: queued.id, in: convId) { $0.uploaded = true }
                case .refused(let why): updateAttachment(attachment.id, of: queued.id, in: convId) { $0.failure = why }
                case .interrupted: return false
                }
            }
            // As stored now: uploads changed it.
            guard let item = conversations[convId]?.items.first(where: { $0.id == queued.id }) else { continue }
            let files = (item.attachments ?? []).filter { $0.uploaded == true && $0.failure == nil }.map(\.wire)
            guard !item.text.isEmpty || !files.isEmpty else { continue }
            let message = V3Message(convId: convId, messageId: item.id, text: item.text, attachments: files.isEmpty ? nil : files)
            guard await connection.send(message) else { return false }
            mark(item.id, .sending, in: convId)
        }
        return true
    }

    private func updateAttachment(_ id: String, of itemId: String, in convId: String, _ change: (inout ChatAttachment) -> Void) {
        guard var conversation = conversations[convId], let index = conversation.items.firstIndex(where: { $0.id == itemId }),
              let file = conversation.items[index].attachments?.firstIndex(where: { $0.id == id }) else { return }
        change(&conversation.items[index].attachments![file])
        store(conversation)
    }

    /// Asks the plugin for a reply's file (an image on screen, a file tapped); no-op once it is here.
    func fetch(_ attachment: ChatAttachment) {
        transfers.fetch(attachment)
    }

    private func receive(_ event: V3Event) {
        switch event {
        case .delivered(let ref):
            mark(ref.messageId, .delivered, in: ref.convId)
        case .runStarted(let ref):
            mark(ref.messageId, .read, in: ref.convId)
            setTyping(ref.convId, true)
        case .typing(let t):
            setTyping(t.convId, t.active)
        case .reply(let reply):
            if reply.convId != foreground, conversations[reply.convId]?.items.contains(where: { $0.id == reply.messageId }) != true {
                let title = conversations[reply.convId]?.displayTitle ?? ""
                let text = reply.text.isEmpty ? (reply.attachments?.first.map { "📎 \($0.name)" } ?? "") : reply.text
                // In front: the in-app notice. Behind, on the Mac (no relay push reaches it): a local notice.
                if active {
                    showNotice(convId: reply.convId, title: title, text: text)
                } else {
                    #if os(macOS)
                    V3Notices.reply(convId: reply.convId, title: title, text: text)
                    #endif
                }
            }
            let files = ChatAttachment.list(reply.attachments)
            append(ChatItem(id: reply.messageId, kind: .agent, text: reply.text, ts: reply.ts, attachments: files), to: reply.convId)
        case .uploadAck, .chunk:
            transfers.receive(event)
        case .tool(let tool):
            self.tool(tool)
        case .readCursor(let cursor):
            receive(cursor)
        case .error(let error) where error.attachmentId != nil:
            transfers.receive(event)
        case .error(let error):
            if error.code == "internal", inFlight != nil { settle() }
            guard let convId = error.convId, V3Event.isId(convId) else { return }
            let id = "error:\(error.messageId ?? V3Event.newId())"
            let text = error.code == "run_failed"
                ? String(localized: "The agent run failed: \(error.message)")
                : String(localized: "The host couldn’t handle this: \(error.message)")
            append(ChatItem(id: id, kind: .error, text: text, ts: Self.now), to: convId)
            setTyping(convId, false)
        case .convList(let list):
            guard let summaries = list.conversations else { return }
            settle()
            // Deleted on the host while this device was away: a conversation the host does not list although this
            // device synced it before (it has a `rev`), or one it holds no message of. A new conversation whose first
            // message the host may not have recorded yet has neither and stays. Not when the list may be cut at 2000.
            let listed = Set(summaries.map(\.convId))
            if summaries.count < 2000 {
                for gone in conversations.values where !listed.contains(gone.id) && (gone.rev != nil || gone.items.isEmpty) {
                    forget(gone.id)
                }
            }
            for summary in summaries {
                var conversation = conversations[summary.convId]
                    ?? Conversation(id: summary.convId, createdAt: summary.updatedAt, updatedAt: summary.updatedAt)
                let isNew = conversations[summary.convId] == nil
                let changed = conversation.title != summary.title || (conversation.archived == true) != (summary.archived == true)
                conversation.title = summary.title
                conversation.archived = summary.archived == true ? true : nil
                if isNew || changed || summary.updatedAt > conversation.updatedAt {
                    conversation.updatedAt = max(conversation.updatedAt, summary.updatedAt)
                    store(conversation)
                }
                if conversation.rev != summary.rev { enqueue(catchUp(conversation)) }
            }
        case .history(let page):
            settle()
            history(page)
        case .cronList(let list):
            // A request has neither; only the plugin's answer does.
            guard list.jobs != nil || list.error != nil else { return }
            // A failed read keeps the last list on screen, under the error.
            if let jobs = list.jobs, list.error == nil { crons = jobs }
            cronsError = list.error
            finishCronWait()
        case .convUpdate(let update):
            apply(update)
        case .deviceList(let list):
            // A request has neither; only the plugin's answer does.
            guard list.devices != nil || list.error != nil else { return }
            if let devices = list.devices { self.devices = devices }
            devicesError = list.error
        case .pairInvite(let answer):
            // A request has none of these; only the plugin's answer does.
            guard answer.link != nil || answer.error != nil else { return }
            invite = answer
        case .peerInfo, .message, .upload, .download, .foreground, .historyRequest, .convPatch, .devicePatch, .unknown:
            break
        }
    }

    // MARK: History

    /// Opening a conversation: fetch what is newer than the cache, first.
    func open(_ convId: String) {
        guard V3Event.isId(convId), let conversation = conversations[convId] else { return }
        enqueue(catchUp(conversation), first: true)
    }

    /// Scrolled to the top: the page before the oldest cached item.
    func loadOlder(_ convId: String) {
        guard let conversation = conversations[convId], conversation.complete != true, !loadingOlder.contains(convId) else { return }
        guard let oldest = conversation.oldestSeq else { return enqueue(catchUp(conversation), first: true) }
        loadingOlder.insert(convId)
        enqueue(.historyRequest(V3HistoryRequest(convId: convId, before: oldest)), first: true)
    }

    private func catchUp(_ conversation: Conversation) -> V3Event {
        .historyRequest(V3HistoryRequest(convId: conversation.id, after: conversation.newestSeq))
    }

    /// A new session: whatever was queued or in flight on the old one is asked again from the top.
    private func startSync() {
        requests = [.convList(V3ConvList())]
        loadingOlder = []
        settle()
    }

    private func enqueue(_ request: V3Event, first: Bool = false) {
        guard request != inFlight else { return }
        requests.removeAll { $0 == request }
        if first { requests.insert(request, at: 0) } else { requests.append(request) }
        pump()
    }

    /// The answer (or the timeout) for the request in flight: the next one may go.
    private func settle() {
        inFlight = nil
        inFlightTimer?.cancel()
        inFlightTimer = nil
        pump()
    }

    private func pump() {
        guard inFlight == nil, state == .ready, let connection, !requests.isEmpty else { return }
        let request = requests.removeFirst()
        inFlight = request
        inFlightTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.requestTimeout)
            guard !Task.isCancelled, let self, self.inFlight == request else { return }
            if case .historyRequest(let r) = request { self.loadingOlder.remove(r.convId) }
            self.settle()
        }
        Task {
            // Not on the socket: the next session starts the sync again.
            let sent = await connection.send(request)
            if !sent, inFlight == request {
                inFlight = nil
                inFlightTimer?.cancel()
                if case .historyRequest(let r) = request { loadingOlder.remove(r.convId) }
            }
        }
    }

    // MARK: Devices (Settings)

    /// The host lists and changes its devices from here: it said so in `peer_info`.
    var devicesAvailable: Bool { hostInfo?.capabilities.contains(V3Devices.capability) == true }

    func refreshDevices() {
        guard devicesAvailable else { return }
        transmit(.deviceList(V3DeviceList()))
    }

    /// The host makes pairing codes for a device added from this one.
    var inviteAvailable: Bool { hostInfo?.capabilities.contains(V3Invite.capability) == true }

    /// Asks the host for a one-time code for another device (owner, 2026-10-17); it lands in ``invite``.
    func requestInvite() {
        invite = nil
        transmit(.pairInvite(V3PairInvite()))
    }

    /// Push for one device on or off, on the host.
    func setPush(_ on: Bool, for id: String) {
        transmit(.devicePatch(V3DevicePatch(id: id, push: on)))
    }

    /// Takes another device off the host: its pairing ends there, and the relay forgets it.
    func removeDevice(_ id: String) {
        transmit(.devicePatch(V3DevicePatch(id: id, removed: true)))
    }

    /// Unpair from Settings: the host forgets this device too, when it can, then this device forgets the host.
    func unpairEverywhere() async {
        if let me = devices?.first(where: \.current), let connection {
            _ = await connection.send(.devicePatch(V3DevicePatch(id: me.id, removed: true)))
            try? await Task.sleep(for: .milliseconds(500))
        }
        unpair()
    }

    // MARK: Crons

    /// Asks the plugin for the jobs and returns once it answers, or after 10 s; at once while there is no session.
    func refreshCrons() async {
        guard let connection, await connection.send(.cronList(V3CronList())) else { return }
        await withCheckedContinuation { continuation in
            cronWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finishCronWait()
            }
        }
    }

    private func history(_ page: V3History) {
        guard V3Event.isId(page.convId) else { return }
        let now = Self.now
        var conversation = conversations[page.convId] ?? Conversation(id: page.convId, createdAt: now, updatedAt: 0)
        conversation.merge(page.items.map(ChatItem.init))
        let seqs = page.items.map(\.seq)
        if let low = seqs.min(), page.after == nil { conversation.oldestSeq = min(conversation.oldestSeq ?? low, low) }
        if let high = seqs.max(), page.before == nil { conversation.newestSeq = max(conversation.newestSeq ?? high, high) }
        if page.before != nil || page.after == nil {
            // A newest page says it afresh: one fetched before the session existed was empty and "complete".
            conversation.complete = !page.more
            loadingOlder.remove(page.convId)
        }
        if page.before == nil {
            // A forward page with more behind it: keep going, ahead of the other conversations.
            if page.after != nil && page.more {
                enqueue(.historyRequest(V3HistoryRequest(convId: page.convId, after: conversation.newestSeq)), first: true)
            } else {
                conversation.rev = page.rev
            }
        }
        if conversation.createdAt > (conversation.items.first?.ts ?? .max) { conversation.createdAt = conversation.items[0].ts }
        store(conversation)
    }

    private func finishCronWait() {
        for waiter in cronWaiters { waiter.resume() }
        cronWaiters = []
    }

    /// A message's mark only moves forward. `convId` nil: look it up (the relay's `accepted` names no conversation).
    private func mark(_ messageId: String, _ status: SendStatus, in convId: String? = nil) {
        guard let convId = convId ?? conversations.first(where: { $0.value.items.contains { $0.id == messageId } })?.key,
              var conversation = conversations[convId],
              let index = conversation.items.firstIndex(where: { $0.id == messageId && $0.kind == .user }),
              (conversation.items[index].status ?? .queued) < status else { return }
        conversation.items[index].status = status
        store(conversation)
    }

    /// Dedupes by id: a reply seen twice (a resend, two sessions) is one bubble.
    private func append(_ item: ChatItem, to convId: String) {
        guard V3Event.isId(convId) else { return }
        let now = Self.now
        var conversation = conversations[convId]
            ?? Conversation(id: convId, createdAt: now, updatedAt: now, read: unplacedReads.removeValue(forKey: convId))
        guard !conversation.items.contains(where: { $0.id == item.id }) else { return }
        conversation.items.append(item)
        conversation.updatedAt = now
        store(conversation)
    }

    /// One collapsed row per user message's run, placed when its first call arrives; the last status of a call wins.
    private func tool(_ tool: V3Tool) {
        let id = "tools:\(tool.messageId)"
        var conversation = conversations[tool.convId]
        if conversation?.items.contains(where: { $0.id == id }) != true {
            append(ChatItem(id: id, kind: .tools, text: "", ts: Self.now, tools: []), to: tool.convId)
            conversation = conversations[tool.convId]
        }
        guard var conversation, let index = conversation.items.firstIndex(where: { $0.id == id }) else { return }
        var calls = conversation.items[index].tools ?? []
        if let call = calls.firstIndex(where: { $0.id == tool.callId }) {
            calls[call].status = tool.status
            calls[call].name = tool.name
        } else {
            calls.append(ToolCall(id: tool.callId, name: tool.name, status: tool.status))
        }
        conversation.items[index].tools = calls
        store(conversation)
    }

    private func store(_ conversation: Conversation) {
        conversations[conversation.id] = conversation
        cache.save(conversation)
        updateBadge()
        publishShareDirectory()
    }

    // MARK: Share extension (#430)

    /// What the share extension left in the App Group, oldest first: each share becomes a message in the conversation
    /// it names (a new one when it names none or one this device no longer has), files uploading through the outbox.
    func takeShares() {
        guard paired else { return }
        for (share, folder) in ShareInbox.pending() {
            let convId = share.convId.flatMap { V3Event.isId($0) ? $0 : nil } ?? V3Event.newId()
            var files: [ChatAttachment] = []
            if let name = share.fileName {
                do {
                    files.append(try AttachmentStaging.stage(file: folder.appending(path: name), limit: mediaMaxBytes))
                } catch {
                    append(ChatItem(id: "error:\(V3Event.newId())", kind: .error, text: error.localizedDescription, ts: Self.now), to: convId)
                }
            }
            send(share.text, attachments: files, in: convId)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The extension's picker: the newest conversations, and the host's limit.
    private func publishShareDirectory() {
        guard paired else { return }
        let rows = list.prefix(30).map { conversation in
            let title = conversation.displayTitle
            return ShareInbox.Conversation(id: conversation.id, title: String(title.prefix(80)))
        }
        ShareInbox.publish(.init(conversations: Array(rows), maxBytes: mediaMaxBytes))
    }

    // MARK: Titles, archive, delete (#428)

    /// Rename: `title` empty (or only spaces) goes back to the generated title. Shown here at once; every device gets
    /// the host's `conv_update`. Nothing happens without a session: the menu items are off then.
    func rename(_ convId: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        patch(V3ConvPatch(convId: convId, title: title)) { $0.title = title.isEmpty ? $0.title : title }
    }

    func setArchived(_ convId: String, _ archived: Bool) {
        patch(V3ConvPatch(convId: convId, archived: archived)) { $0.archived = archived ? true : nil }
    }

    /// Delete on the host (archive, then delete with its transcript) and on every device.
    func delete(_ convId: String) {
        patch(V3ConvPatch(convId: convId, deleted: true)) { _ in }
    }

    /// A rename, archive or delete needs a live session; the host answers every device.
    var canPatch: Bool { state == .ready }

    private func patch(_ patch: V3ConvPatch, local: @escaping (inout Conversation) -> Void) {
        guard let connection, V3Event.isId(patch.convId) else { return }
        Task {
            guard await connection.send(.convPatch(patch)) else { return }
            if patch.deleted == true { return forget(patch.convId) }
            guard var conversation = conversations[patch.convId] else { return }
            local(&conversation)
            store(conversation)
        }
    }

    /// The host's word on a conversation: its title and archive state now, or that it is gone.
    private func apply(_ update: V3ConvUpdate) {
        if update.deleted == true { return forget(update.convId) }
        var conversation = conversations[update.convId]
            ?? Conversation(id: update.convId, createdAt: Self.now, updatedAt: Self.now, read: unplacedReads.removeValue(forKey: update.convId))
        conversation.title = update.title
        conversation.archived = update.archived == true ? true : nil
        guard conversation != conversations[update.convId] else { return }
        store(conversation)
    }

    /// The conversation deleted last (on any device): a view showing it closes it.
    private(set) var deleted: String?

    private func forget(_ convId: String) {
        guard let gone = conversations.removeValue(forKey: convId) else { return }
        deleted = convId
        cache.remove(convId)
        // Its files go with it (#430).
        for file in gone.items.flatMap({ $0.attachments ?? [] }) { AttachmentFiles.remove(file) }
        typing.remove(convId)
        automationDrafts[convId] = nil
        updateBadge()
        publishShareDirectory()
    }

    // MARK: Read marks (#429)

    /// The conversation is on screen. `explicit` (it was opened, or Mark as Read) also clears Mark as Unread; an
    /// automatic read (a reply arrived while it is open) only moves the cursor up to the newest reply.
    func markRead(_ convId: String, explicit: Bool) {
        guard let conversation = conversations[convId], let latest = conversation.latestReply else { return }
        let held = conversation.read
        let unread = explicit ? false : held?.unread == true
        let ahead = latest.ts > (held?.ts ?? .min)
        guard ahead || held?.unread != unread else { return }
        setRead(V3ReadCursor(convId: convId, messageId: ahead ? latest.id : held!.messageId,
            ts: ahead ? latest.ts : held!.ts, unread: unread), in: conversation)
    }

    /// Mark as Unread: the cursor stays where it is (it never moves back), the flag holds until the next read.
    func markUnread(_ convId: String) {
        guard let conversation = conversations[convId], var cursor = conversation.read, !cursor.unread else { return }
        cursor.unread = true
        setRead(cursor, in: conversation)
    }

    private func setRead(_ cursor: V3ReadCursor, in conversation: Conversation) {
        var conversation = conversation
        conversation.read = cursor
        conversation.readPending = true
        store(conversation)
        transmit(.readCursor(cursor))
        if !cursor.unread { V3Notices.removeDelivered(convId: cursor.convId, readUpTo: cursor.ts) }
    }

    /// The plugin's merged cursor. While this device's own is unanswered, the cursor takes the further of the two and
    /// the flag stays this device's, until the plugin's answer to it (at least as far, same flag) arrives.
    private func receive(_ cursor: V3ReadCursor) {
        // Read on any device: its alerts here go, up to the reply it was read at.
        if !cursor.unread { V3Notices.removeDelivered(convId: cursor.convId, readUpTo: cursor.ts) }
        guard var conversation = conversations[cursor.convId] else {
            unplacedReads[cursor.convId] = cursor
            return
        }
        if conversation.readPending == true, let mine = conversation.read {
            if cursor.ts >= mine.ts && cursor.unread == mine.unread {
                conversation.readPending = nil
                conversation.read = cursor
            } else if cursor.ts > mine.ts {
                conversation.read = V3ReadCursor(convId: cursor.convId, messageId: cursor.messageId, ts: cursor.ts, unread: mine.unread)
            }
        } else {
            conversation.read = cursor
        }
        guard conversation != conversations[cursor.convId] else { return }
        store(conversation)
    }

    private func transmit(_ event: V3Event) {
        guard let connection else { return }
        Task { await connection.send(event) }
    }

    /// Every unread reply, on the app icon (iOS: shown once notifications are allowed, #431) or the Dock tile.
    private func updateBadge() {
        let total = conversations.values.reduce(0) { $0 + $1.unreadCount }
        guard total != badge else { return }
        badge = total
        #if os(iOS)
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(total) }
        #else
        NSApplication.shared.dockTile.badgeLabel = total > 0 ? String(total) : nil
        #endif
    }

    private func setTyping(_ convId: String, _ active: Bool) {
        typingTimers[convId]?.cancel()
        typingTimers[convId] = nil
        guard active else {
            typing.remove(convId)
            return
        }
        typing.insert(convId)
        typingTimers[convId] = Task { [weak self] in
            try? await Task.sleep(for: Self.typingTimeout)
            guard !Task.isCancelled else { return }
            self?.typing.remove(convId)
        }
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

extension V3Connection.State {
    /// The list's subtitle.
    var label: String {
        switch self {
        case .ready: String(localized: "Connected")
        case .connecting, .handshaking: String(localized: "Connecting…")
        case .hostOffline: String(localized: "Host offline")
        case .offline: String(localized: "Offline")
        case .updateRequired: String(localized: "Update required")
        case .pairingFailed: String(localized: "Couldn’t pair")
        case .unpaired: String(localized: "Removed from the host")
        }
    }
}

/// The in-app notice (Settings, #415): a reply in a conversation not on screen while the app is in front.
struct V3InAppNotice: Equatable, Identifiable {
    let id = UUID()
    let convId: String
    let title: String
    let text: String
}
