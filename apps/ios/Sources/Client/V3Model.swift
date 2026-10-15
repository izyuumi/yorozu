import Foundation
import Observation
import YorozuWire
#if os(iOS)
import UserNotifications
#else
import AppKit
#endif

/// The v3 client (#425): one pairing with the OpenClaw plugin, the conversations cached on this device, and the link.
/// User messages without `delivered` are the outbox: each new session sends them again, and the plugin drops a
/// `messageId` it already took.
@MainActor @Observable
final class V3Model {
    private(set) var pairing: V3Pairing?
    private(set) var state = V3Connection.State.offline
    private(set) var conversations: [String: Conversation] = [:]
    /// Conversations whose agent is working: from `run_started` or `typing {active}` until `typing {active: false}`,
    /// or 30 s without a repeat.
    private(set) var typing: Set<String> = []
    /// A scanned or pasted code waiting for the user to compare the host fingerprint.
    var pendingPairing: QrPayload?
    /// Why the last pairing attempt failed, for the pairing screen.
    var pairingError: String?
    /// The Crons tab (#432): the configured agent's jobs as the plugin last sent them, nil before the first answer.
    private(set) var crons: [V3CronJob]?
    /// Why the plugin could not list them, from its last answer.
    private(set) var cronsError: String?
    /// Text waiting for a conversation's composer ("Edit in chat"); the chat takes it once, unsent.
    var drafts: [String: String] = [:]

    @ObservationIgnored private var connection: V3Connection?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var typingTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let cache = ConversationCache()
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
    @ObservationIgnored private var cronWaiters: [CheckedContinuation<Void, Never>] = []

    static let typingTimeout: Duration = .seconds(30)

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

    /// Newest first.
    var list: [Conversation] {
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
    }

    // MARK: Link

    private func connect() {
        guard let pairing else { return }
        let local = V3PeerInfo(app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            name: DeviceModel.name, capabilities: [V3Attachment.capability])
        guard let connection = try? V3Connection(pairing: pairing.pairing, identity: pairing.identity,
            relayKnows: pairing.relayKnows, local: local) else {
            return failPairing(String(localized: "This pairing code can’t be used."))
        }
        self.connection = connection
        listener = Task { [weak self] in
            let updates = await connection.updates()
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
        takeShares()
        guard let connection else { return connect() }
        Task { await connection.reconnect() }
    }

    /// iOS suspends a background app: hang up, so the relay does not hold a frozen socket.
    func suspend() {
        guard let connection else { return }
        Task { await connection.stop() }
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
            publishShareDirectory()
            takeShares()
            pumpOutbox(resend: true)
            transfers.resumeDownloads()
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
            let files = reply.attachments?.map { ChatAttachment(id: $0.id, name: $0.name, mime: $0.mime, size: $0.size) }
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
            guard let convId = error.convId, V3Event.isId(convId) else { return }
            let id = "error:\(error.messageId ?? V3Event.newId())"
            let text = error.code == "run_failed"
                ? String(localized: "The agent run failed: \(error.message)")
                : String(localized: "The host couldn’t handle this: \(error.message)")
            append(ChatItem(id: id, kind: .error, text: text, ts: Self.now), to: convId)
            setTyping(convId, false)
        case .cronList(let list):
            // A request has neither; only the plugin's answer does.
            guard list.jobs != nil || list.error != nil else { return }
            // A failed read keeps the last list on screen, under the error.
            if let jobs = list.jobs, list.error == nil { crons = jobs }
            cronsError = list.error
            finishCronWait()
        case .peerInfo, .message, .upload, .download, .unknown:
            break
        }
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
            let title = conversation.preview.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return ShareInbox.Conversation(id: conversation.id, title: String(title.prefix(80)))
        }
        ShareInbox.publish(.init(conversations: Array(rows), maxBytes: mediaMaxBytes))
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
    }

    /// The plugin's merged cursor. While this device's own is unanswered, the cursor takes the further of the two and
    /// the flag stays this device's, until the plugin's answer to it (at least as far, same flag) arrives.
    private func receive(_ cursor: V3ReadCursor) {
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
