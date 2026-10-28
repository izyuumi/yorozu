import Foundation
import Observation
import OSLog
import UserNotifications
import YorozuWire
#if os(macOS)
import AppKit
#endif

@MainActor @Observable
final class AppModel {
    private(set) var pairing: Pairing?
    private(set) var isDemo = false
    private(set) var state = RelayConnection.State.offline
    private(set) var conversations: [String: Conversation] = [:]
    private(set) var typing: Set<String> = []
    private(set) var loadingOlder: Set<String> = []
    var pendingPairing: QrPayload?
    var pairingError: String?
    var requestedConversation: String?
    private(set) var foreground: String?
    private(set) var crons: [CronJob]?
    private(set) var cronsError: String?
    var automationDrafts: [String: CronJob] = [:]
    @ObservationIgnored var textDrafts: [String: String] = [:]
    @ObservationIgnored private var onScreen: Set<String> = []
    private(set) var devices: [DeviceInfo]?
    private(set) var devicesError: String?
    private(set) var invite: PairInvite?
    var notice: InAppNotice?
    var pendingDevice: DeviceCode?
    var deviceAdding: DeviceAdding?
    var deviceCode: DeviceCode?

    @ObservationIgnored private var connection: (any ClientTransport)?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var typingTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let cache = ConversationCache()
    @ObservationIgnored private var requests: [WireEvent] = []
    @ObservationIgnored private var inFlight: WireEvent?
    @ObservationIgnored private var inFlightTimer: Task<Void, Never>?
    @ObservationIgnored private var unplacedReads: [String: ReadCursor] = [:]
    @ObservationIgnored private var badge: Int?
    private(set) var hostInfo: PeerInfo?
    let transfers = Transfers()
    @ObservationIgnored private var outboxPumping = false
    @ObservationIgnored private var outboxAgain = false
    @ObservationIgnored private var outboxResend = false
    @ObservationIgnored private var visible: String?
    @ObservationIgnored private(set) var active = false
    @ObservationIgnored private var activeSent = false
    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private var cronWaiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var liveStateLoaded = false
    @ObservationIgnored private var liveSnapshot: LiveSnapshot?
    private struct LiveSnapshot {
        var pairing: Pairing?
        var conversations: [String: Conversation]
        var crons: [CronJob]?
        var hostInfo: PeerInfo?
    }
    private static let logger = Logger(subsystem: "to.yumi.yorozu", category: "Demo")

    static let typingTimeout: Duration = .seconds(30)
    static let requestTimeout: Duration = .seconds(30)

    init() {
        transfers.send = { [weak self] event in
            guard let self, !self.isDemo, let connection = self.connection else { return false }
            return await connection.send(event)
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            enterDemo()
            return
        }
        liveStateLoaded = true
        do {
            pairing = try Pairing.load()
        } catch {
            pairingError = String(localized: "Couldn’t read this device’s pairing: \(error.localizedDescription)")
        }
        guard pairing != nil else { return }
        for conversation in cache.loadAll() { conversations[conversation.id] = conversation }
        updateBadge()
        connect()
        takeShares()
    }

    var paired: Bool { isDemo || pairing?.paired == true }
    var connecting: Bool { pairing != nil && !paired }

    var list: [Conversation] { sorted.filter { $0.archived != true } }

    var archivedList: [Conversation] { sorted.filter { $0.archived == true } }

    private var sorted: [Conversation] {
        conversations.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    var fingerprint: String? { pairing?.pairing.fingerprint }

    func submit(_ text: String) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "YOROZU-DEMO" {
            enterDemo()
            return nil
        }
        guard !isDemo else { return String(localized: "Exit demo mode before pairing with a host.") }
        if let code = DeviceCode.decode(text) {
            guard inviteAvailable else {
                return String(localized: "Scan this code with Yorozu on an iPhone or iPad that is already paired.")
            }
            pendingDevice = code
            return nil
        }
        guard let payload = try? QrPayload.decode(text), payload.v == 3, payload.roomId != nil, payload.secret != nil,
              (Data(base64URLEncoded: payload.macPubkey)?.count ?? 0) == 32 else {
            return String(localized: "This isn’t a Yorozu pairing code. Run `openclaw yorozu pair` on the host and use the code it prints.")
        }
        pairingError = nil
        pendingPairing = payload
        return nil
    }

    func confirm(_ payload: QrPayload) {
        guard !isDemo else { return }
        pendingPairing = nil
        disconnect()
        cache.wipe()
        AttachmentFiles.wipe()
        conversations = [:]
        let new = Pairing(pairing: payload, identity: .generate())
        do {
            try new.save()
        } catch {
            pairingError = String(localized: "Couldn’t save the pairing: \(error.localizedDescription)")
            return
        }
        pairing = new
        connect()
    }

    func unpair() {
        if isDemo { return exitDemo() }
        disconnect()
        try? Pairing.remove()
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

    func enterDemo() {
        guard !isDemo else { return }
        liveSnapshot = LiveSnapshot(pairing: pairing, conversations: conversations, crons: crons, hostInfo: hostInfo)
        disconnect()
        resetTransientState()
        isDemo = true
        pairing = nil
        conversations = [:]
        crons = DemoData.crons
        hostInfo = nil
        Self.logger.debug("Entering memory-only demo mode")
        listen(to: DemoTransport())
    }

    func exitDemo() {
        guard isDemo else { return }
        disconnect()
        resetTransientState()
        isDemo = false
        pairing = liveSnapshot?.pairing
        conversations = liveSnapshot?.conversations ?? [:]
        crons = liveSnapshot?.crons
        hostInfo = liveSnapshot?.hostInfo
        liveSnapshot = nil
        if !liveStateLoaded {
            liveStateLoaded = true
            do {
                pairing = try Pairing.load()
                if pairing != nil {
                    for conversation in cache.loadAll() { conversations[conversation.id] = conversation }
                }
            } catch {
                pairingError = String(localized: "Couldn’t read this device’s pairing: \(error.localizedDescription)")
            }
        }
        updateBadge()
        Self.logger.debug("Leaving memory-only demo mode")
        connect()
    }

    private func resetTransientState() {
        for timer in typingTimers.values { timer.cancel() }
        typingTimers = [:]
        typing = []
        inFlightTimer?.cancel()
        inFlightTimer = nil
        inFlight = nil
        requests = []
        loadingOlder = []
        unplacedReads = [:]
        transfers.sessionLost()
        finishCronWait()
        pendingPairing = nil
        pairingError = nil
        requestedConversation = nil
        visible = nil
        onScreen = []
        textDrafts = [:]
        foreground = nil
        activeSent = false
        automationDrafts = [:]
        devices = nil
        devicesError = nil
        invite = nil
        pendingDevice = nil
        deviceAdding = nil
        notice = nil
        deleted = nil
        cronsError = nil
    }

    private func connect() {
        guard !isDemo, let pairing else { return }
        let local = PeerInfo(app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            name: DeviceModel.name, capabilities: [Attachment.capability, Devices.capability, ReplyTo.capability])
        guard let connection = try? RelayConnection(pairing: pairing.pairing, identity: pairing.identity,
            relayKnows: pairing.relayKnows, local: local) else {
            return failPairing(String(localized: "This pairing code can’t be used."))
        }
        self.connection = connection
        #if os(iOS)
        if let hostKey = Data(base64URLEncoded: pairing.pairing.macPubkey),
           let key = try? PushPreview.key(myPriv: pairing.identity.sessionPrivateKey, theirPub: hostKey) {
            PreviewKeychain.save(key)
        }
        #endif
        listen(to: connection)
    }

    private func listen(to connection: any ClientTransport) {
        self.connection = connection
        let generation = connectionGeneration
        let pushToken = isDemo ? nil : pushToken
        listener = Task { [weak self] in
            let updates = await connection.updates()
            guard !Task.isCancelled else { return }
            if let pushToken { await connection.registerPush(deviceToken: pushToken) }
            guard !Task.isCancelled else { return }
            await connection.start()
            guard !Task.isCancelled else {
                await connection.stop()
                return
            }
            for await update in updates {
                guard !Task.isCancelled, let self, generation == self.connectionGeneration else { return }
                self.apply(update)
            }
        }
    }

    private func disconnect() {
        connectionGeneration += 1
        listener?.cancel()
        listener = nil
        if let connection { Task { await connection.stop() } }
        connection = nil
        state = .offline
    }

    func resume() {
        setActive(true)
        takeShares()
        guard let connection else { return connect() }
        Task { await connection.reconnect() }
    }

    var hasUnsent: Bool {
        !isDemo && conversations.values.contains { $0.items.contains { $0.kind == .user && ($0.status ?? .queued) < .sent } }
    }

    func waitUntilSent(limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while hasUnsent {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    func suspend() {
        setActive(false)
        guard !isDemo, let connection else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !active else { return }
            await connection.stop()
        }
    }

    func setActive(_ active: Bool) {
        self.active = active
        updateForeground()
    }

    func setVisible(_ convId: String?, leaving: String? = nil) {
        if convId == nil, let leaving, visible != leaving { return }
        visible = convId
        updateForeground()
        if !isDemo, let convId { Notices.removeDelivered(convId: convId) }
    }

    func setOnScreen(_ convId: String, _ shown: Bool) {
        if shown { onScreen.insert(convId) } else { onScreen.remove(convId) }
    }

    private func inView(_ convId: String) -> Bool {
        convId == foreground || (active && onScreen.contains(convId))
    }

    private func updateForeground() {
        let next = active ? visible : nil
        guard next != foreground || active != activeSent else { return }
        foreground = next
        activeSent = active
        transmit(.foreground(Foreground(convId: next, active: active)))
    }

    func backgroundWake() async {
        guard !isDemo, paired, !active else { return }
        let generation = connectionGeneration
        if let connection { await connection.reconnect() } else { connect() }
        for _ in 0..<40 where state != .ready {
            guard generation == connectionGeneration, !isDemo else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2))
        guard generation == connectionGeneration, !isDemo, !active, let connection else { return }
        await connection.stop()
    }

    private func showNotice(convId: String, title: String, text: String) {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line, notice?.convId != convId else { return }
        notice = InAppNotice(convId: convId, title: title.isEmpty ? String(localized: "Yorozu replied.") : title, text: line)
    }

    func showNotice(for convId: String, title: String, body: String) {
        guard !isDemo else { return }
        guard !inView(convId) else { return }
        showNotice(convId: convId, title: title, text: body)
    }

    func registerPush(_ token: String) {
        pushToken = token
        guard !isDemo, let connection else { return }
        let generation = connectionGeneration
        Task {
            guard generation == connectionGeneration, !isDemo else { return }
            await connection.registerPush(deviceToken: token)
        }
    }

    func conversation(convId: String?, ref: String?) -> String? {
        if let convId, WireEvent.isId(convId) { return convId }
        guard let ref else { return nil }
        return conversations.keys.first { YorozuCrypto.threadRef($0) == ref }
    }

    func requestNotifications() {
        guard !isDemo, paired else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard !isDemo else { return }
            badge = nil
            updateBadge()
        }
    }

    private func apply(_ update: RelayConnection.Update) {
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
            if !isDemo { transfers.resumeDownloads() }
            if active { transmit(.foreground(Foreground(convId: foreground, active: true))) }
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

    private func updatePairing(_ change: (inout Pairing) -> Void) {
        guard !isDemo, var pairing else { return }
        change(&pairing)
        self.pairing = pairing
        try? pairing.save()
    }

    func send(_ text: String, attachments: [ChatAttachment] = [], in convId: String, messageId: String = WireEvent.newId(),
        replyingTo target: ChatItem? = nil) {
        guard !isDemo || attachments.isEmpty else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, WireEvent.isId(convId), WireEvent.isId(messageId) else { return }
        var item = ChatItem(id: messageId, kind: .user, text: text, ts: Self.now, status: .queued,
            attachments: attachments.isEmpty ? nil : attachments, replyTo: target.map { ReplyTo(messageId: $0.id, text: $0.summary) })
        if attachments.count > Attachment.maxPerMessage {
            item.rejected = String(localized: "A message can carry up to \(Attachment.maxPerMessage) attachments.")
        }
        append(item, to: convId)
        pumpOutbox(resend: false)
    }

    var attachmentsAvailable: Bool { !isDemo && (hostInfo.map { $0.capabilities.contains(Attachment.capability) } ?? true) }
    var mediaMaxBytes: Int { hostInfo?.mediaMaxBytes ?? Attachment.defaultMaxBytes }
    var repliesAvailable: Bool { !isDemo && (hostInfo.map { $0.capabilities.contains(ReplyTo.capability) } ?? true) }

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
            if outboxAgain { pumpOutbox(resend: false) }
        }
    }

    private func sendOutbox(all: Bool) async -> Bool {
        let generation = connectionGeneration
        let pending = conversations.values.flatMap { conversation in
            conversation.items.filter { item in
                guard item.kind == .user, item.rejected == nil, let status = item.status,
                      all ? status < .delivered : status == .queued else { return false }
                return !item.text.isEmpty || item.attachments?.contains { $0.failure == nil } == true
            }.map { (conversation.id, $0) }
        }
        for (convId, queued) in pending.sorted(by: { $0.1.ts < $1.1.ts }) {
            guard generation == connectionGeneration, let connection, state == .ready else { return false }
            for attachment in queued.attachments ?? [] where attachment.uploaded != true && attachment.failure == nil {
                switch await transfers.upload(attachment) {
                case .stored: updateAttachment(attachment.id, of: queued.id, in: convId) { $0.uploaded = true }
                case .refused(let why): updateAttachment(attachment.id, of: queued.id, in: convId) { $0.failure = why }
                case .interrupted: return false
                }
            }
            guard let item = conversations[convId]?.items.first(where: { $0.id == queued.id }) else { continue }
            let files = (item.attachments ?? []).filter { $0.uploaded == true && $0.failure == nil }.map(\.wire)
            guard !item.text.isEmpty || !files.isEmpty else { continue }
            let message = Message(convId: convId, messageId: item.id, text: item.text, attachments: files.isEmpty ? nil : files,
                replyTo: repliesAvailable ? item.replyTo : nil)
            guard await connection.send(message), generation == connectionGeneration else { return false }
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

    func fetch(_ attachment: ChatAttachment) {
        guard !isDemo else { return }
        transfers.fetch(attachment)
    }

    private func receive(_ event: WireEvent) {
        switch event {
        case .delivered(let ref):
            mark(ref.messageId, .delivered, in: ref.convId)
            ShareInbox.finish(messageId: ref.messageId)
        case .runStarted(let ref):
            if conversations[ref.convId]?.items.contains(where: { $0.id == ref.messageId }) != true {
                enqueue(.historyRequest(HistoryRequest(convId: ref.convId, after: conversations[ref.convId]?.newestSeq)))
            }
            mark(ref.messageId, .read, in: ref.convId)
            ShareInbox.finish(messageId: ref.messageId)
            setTyping(ref.convId, true)
        case .typing(let t):
            setTyping(t.convId, t.active)
        case .reply(let reply):
            if !inView(reply.convId), conversations[reply.convId]?.items.contains(where: { $0.id == reply.messageId }) != true {
                let title = conversations[reply.convId]?.displayTitle ?? ""
                let text = reply.text.isEmpty ? (reply.attachments?.first.map { "📎 \($0.name)" } ?? "") : reply.text
                if active {
                    showNotice(convId: reply.convId, title: title, text: text)
                } else {
                    #if os(macOS)
                    if !isDemo { Notices.reply(convId: reply.convId, title: title, text: text) }
                    #endif
                }
            }
            let files = ChatAttachment.list(reply.attachments)
            append(ChatItem(id: reply.messageId, kind: .agent, text: reply.text, ts: reply.ts, attachments: files, replyTo: reply.replyTo),
                to: reply.convId)
        case .uploadAck, .chunk:
            transfers.receive(event)
        case .tool(let tool):
            self.tool(tool)
        case .readCursor(let cursor):
            receive(cursor)
        case .error(let error) where error.attachmentId != nil:
            transfers.receive(event)
        case .error(let error):
            if ["internal", "bad_request", "unsupported"].contains(error.code), inFlight != nil { settle() }
            guard let convId = error.convId, WireEvent.isId(convId), let messageId = error.messageId else { return }
            reject(messageId, in: convId, error.message)
            let id = "error:\(messageId)"
            let text = error.code == "run_failed"
                ? String(localized: "The agent run failed: \(error.message)")
                : String(localized: "The host couldn’t handle this: \(error.message)")
            append(ChatItem(id: id, kind: .error, text: text, ts: Self.now), to: convId)
            setTyping(convId, false)
        case .convList(let list):
            guard let summaries = list.conversations else { return }
            settle()
            let listed = Set(summaries.map(\.convId))
            if summaries.count < 2000 {
                for gone in conversations.values where !listed.contains(gone.id) && (gone.rev != nil || gone.items.isEmpty)
                    && !gone.items.contains(where: { $0.kind == .user && ($0.status ?? .queued) < .delivered }) {
                    forget(gone.id)
                }
            }
            for summary in summaries {
                var conversation = conversations[summary.convId]
                    ?? Conversation(id: summary.convId, createdAt: summary.updatedAt, updatedAt: summary.updatedAt,
                        read: unplacedReads.removeValue(forKey: summary.convId))
                let isNew = conversations[summary.convId] == nil
                let changed = conversation.title != summary.title || (conversation.archived == true) != (summary.archived == true)
                    || conversation.pinnedAt != summary.pinnedAt
                conversation.title = summary.title
                conversation.archived = summary.archived == true ? true : nil
                conversation.pinnedAt = summary.pinnedAt
                let sending = conversation.items.filter { $0.kind == .user && ($0.status ?? .queued) < .delivered }.map(\.ts).max()
                let time = max(summary.updatedAt, sending ?? .min)
                if isNew || changed || time != conversation.updatedAt {
                    conversation.updatedAt = time
                    store(conversation)
                }
                if conversation.rev != summary.rev { enqueue(catchUp(conversation)) }
            }
        case .history(let page):
            settle()
            history(page)
        case .cronList(let list):
            guard list.jobs != nil || list.error != nil else { return }
            if let jobs = list.jobs, list.error == nil { crons = jobs }
            cronsError = list.error
            finishCronWait()
        case .convUpdate(let update):
            apply(update)
        case .deviceList(let list):
            guard list.devices != nil || list.error != nil else { return }
            if let devices = list.devices { self.devices = devices }
            devicesError = list.error
        case .pairInvite(let answer):
            guard answer.link != nil || answer.error != nil else { return }
            invite = answer
            if case .asking(let code) = deviceAdding { deliver(answer, to: code) }
        case .peerInfo, .message, .upload, .download, .foreground, .historyRequest, .convPatch, .devicePatch, .unknown:
            break
        }
    }

    func open(_ convId: String) {
        guard WireEvent.isId(convId), let conversation = conversations[convId] else { return }
        enqueue(catchUp(conversation), first: true)
    }

    func loadOlder(_ convId: String) {
        guard let conversation = conversations[convId], conversation.complete != true, !loadingOlder.contains(convId) else { return }
        guard let oldest = conversation.oldestSeq else { return enqueue(catchUp(conversation), first: true) }
        loadingOlder.insert(convId)
        enqueue(.historyRequest(HistoryRequest(convId: convId, before: oldest)), first: true)
    }

    private func catchUp(_ conversation: Conversation) -> WireEvent {
        .historyRequest(HistoryRequest(convId: conversation.id, after: conversation.newestSeq))
    }

    private func startSync() {
        requests = [.convList(ConvList())]
        loadingOlder = []
        settle()
    }

    private func enqueue(_ request: WireEvent, first: Bool = false) {
        guard request != inFlight else { return }
        requests.removeAll { $0 == request }
        if first { requests.insert(request, at: 0) } else { requests.append(request) }
        pump()
    }

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
            let sent = await connection.send(request)
            if !sent, inFlight == request {
                inFlight = nil
                inFlightTimer?.cancel()
                if case .historyRequest(let r) = request { loadingOlder.remove(r.convId) }
            }
        }
    }

    var devicesAvailable: Bool { isDemo || hostInfo?.capabilities.contains(Devices.capability) == true }

    func refreshDevices() {
        guard devicesAvailable else { return }
        transmit(.deviceList(DeviceList()))
    }

    var inviteAvailable: Bool { !isDemo && hostInfo?.capabilities.contains(Invite.capability) == true }

    func requestInvite() {
        guard !isDemo else { return }
        invite = nil
        transmit(.pairInvite(PairInvite()))
    }

    func setPush(_ on: Bool, for id: String) {
        guard !isDemo else { return }
        transmit(.devicePatch(DevicePatch(id: id, push: on)))
    }

    func removeDevice(_ id: String) {
        guard !isDemo else { return }
        transmit(.devicePatch(DevicePatch(id: id, removed: true)))
    }

    func unpairEverywhere() async {
        if isDemo { return exitDemo() }
        if let me = devices?.first(where: \.current), let connection {
            _ = await connection.send(.devicePatch(DevicePatch(id: me.id, removed: true)))
            try? await Task.sleep(for: .milliseconds(500))
        }
        unpair()
    }

    func refreshCrons() async {
        if isDemo {
            crons = DemoData.crons
            return
        }
        guard let connection, await connection.send(.cronList(CronList())) else { return }
        await withCheckedContinuation { continuation in
            cronWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finishCronWait()
            }
        }
    }

    private func history(_ page: History) {
        guard WireEvent.isId(page.convId) else { return }
        let now = Self.now
        var conversation = conversations[page.convId] ?? Conversation(id: page.convId, createdAt: now, updatedAt: 0,
            read: unplacedReads.removeValue(forKey: page.convId))
        conversation.merge(page.items.map(ChatItem.init))
        let seqs = page.items.map(\.seq)
        if let low = seqs.min(), page.after == nil { conversation.oldestSeq = min(conversation.oldestSeq ?? low, low) }
        if let high = seqs.max(), page.before == nil { conversation.newestSeq = max(conversation.newestSeq ?? high, high) }
        if page.before != nil || page.after == nil {
            conversation.complete = !page.more
            loadingOlder.remove(page.convId)
        }
        if page.before == nil {
            if page.after != nil && page.more {
                enqueue(.historyRequest(HistoryRequest(convId: page.convId, after: conversation.newestSeq)), first: true)
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

    private func mark(_ messageId: String, _ status: SendStatus, in convId: String? = nil) {
        guard let convId = convId ?? conversations.first(where: { $0.value.items.contains { $0.id == messageId } })?.key,
              var conversation = conversations[convId],
              let index = conversation.items.firstIndex(where: { $0.id == messageId && $0.kind == .user }),
              (conversation.items[index].status ?? .queued) < status else { return }
        conversation.items[index].status = status
        store(conversation)
    }

    private func reject(_ messageId: String, in convId: String, _ reason: String) {
        guard var conversation = conversations[convId],
              let index = conversation.items.firstIndex(where: { $0.id == messageId && $0.kind == .user }),
              (conversation.items[index].status ?? .queued) < .delivered else { return }
        conversation.items[index].rejected = reason
        store(conversation)
        ShareInbox.finish(messageId: messageId)
    }

    private func append(_ item: ChatItem, to convId: String) {
        guard WireEvent.isId(convId) else { return }
        let now = Self.now
        var conversation = conversations[convId]
            ?? Conversation(id: convId, createdAt: now, updatedAt: now, read: unplacedReads.removeValue(forKey: convId))
        guard !conversation.items.contains(where: { $0.id == item.id }) else { return }
        conversation.items.append(item)
        conversation.updatedAt = now
        store(conversation)
    }

    private func tool(_ tool: Tool) {
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
        if !isDemo { cache.save(conversation) }
        updateBadge()
        publishShareDirectory()
    }

    func takeShares() {
        guard !isDemo, paired else { return }
        for (share, folder) in ShareInbox.pending() {
            let messageId = folder.lastPathComponent.lowercased()
            guard WireEvent.isId(messageId) else { continue }
            if let existing = conversations.values.flatMap(\.items).first(where: { $0.id == messageId && $0.kind == .user }) {
                if (existing.status ?? .queued) >= .delivered { ShareInbox.finish(messageId: messageId) }
                else { pumpOutbox(resend: state == .ready) }
                continue
            }
            let convId = share.convId.flatMap { WireEvent.isId($0) && conversations[$0] != nil ? $0 : nil } ?? messageId
            var files: [ChatAttachment] = []
            if let name = share.fileName {
                do {
                    files.append(try AttachmentStaging.stage(file: folder.appending(path: name), limit: mediaMaxBytes))
                } catch {
                    append(ChatItem(id: "error:\(messageId)", kind: .error, text: error.localizedDescription, ts: Self.now), to: convId)
                    continue
                }
            }
            if var conversation = conversations[convId], conversation.items.contains(where: { $0.id == "error:\(messageId)" }) {
                conversation.items.removeAll { $0.id == "error:\(messageId)" }
                store(conversation)
            }
            send(share.text, attachments: files, in: convId, messageId: messageId)
        }
    }

    private func publishShareDirectory() {
        guard !isDemo, paired else { return }
        let rows = list.prefix(30).map { conversation in
            let title = conversation.displayTitle
            return ShareInbox.Conversation(id: conversation.id, title: String(title.prefix(80)))
        }
        ShareInbox.publish(.init(conversations: Array(rows), maxBytes: mediaMaxBytes))
    }

    func rename(_ convId: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        patch(ConvPatch(convId: convId, title: title)) { $0.title = title.isEmpty ? $0.title : title }
    }

    func setArchived(_ convId: String, _ archived: Bool) {
        patch(ConvPatch(convId: convId, archived: archived)) {
            $0.archived = archived ? true : nil
            if archived { $0.pinnedAt = nil }
        }
    }

    func setPinned(_ convId: String, _ pinned: Bool) {
        patch(ConvPatch(convId: convId, pinned: pinned)) { $0.pinnedAt = pinned ? $0.pinnedAt ?? Self.now : nil }
    }

    func delete(_ convId: String) {
        patch(ConvPatch(convId: convId, deleted: true)) { _ in }
    }

    var canPatch: Bool { state == .ready }

    private func patch(_ patch: ConvPatch, local: @escaping (inout Conversation) -> Void) {
        guard let connection, WireEvent.isId(patch.convId) else { return }
        let generation = connectionGeneration
        Task {
            guard await connection.send(.convPatch(patch)), generation == connectionGeneration else { return }
            if patch.deleted == true { return forget(patch.convId) }
            guard var conversation = conversations[patch.convId] else { return }
            local(&conversation)
            store(conversation)
        }
    }

    private func apply(_ update: ConvUpdate) {
        if update.deleted == true { return forget(update.convId) }
        var conversation = conversations[update.convId]
            ?? Conversation(id: update.convId, createdAt: Self.now, updatedAt: Self.now, read: unplacedReads.removeValue(forKey: update.convId))
        conversation.title = update.title
        conversation.archived = update.archived == true ? true : nil
        conversation.pinnedAt = update.pinnedAt
        guard conversation != conversations[update.convId] else { return }
        store(conversation)
    }

    private(set) var deleted: String?

    private func forget(_ convId: String) {
        guard let gone = conversations.removeValue(forKey: convId) else { return }
        deleted = convId
        if !isDemo { cache.remove(convId) }
        let waiting = Set(ShareInbox.pending().map { $0.folder.lastPathComponent.lowercased() })
        let retained = gone.items.filter { $0.kind == .user && ($0.status ?? .queued) < .delivered && waiting.contains($0.id) }
        for item in retained { append(item, to: WireEvent.newId()) }
        if !retained.isEmpty { pumpOutbox(resend: true) }
        if !isDemo {
            for file in gone.items.filter({ item in !retained.contains(where: { $0.id == item.id }) })
                .flatMap({ $0.attachments ?? [] }) { AttachmentFiles.remove(file) }
        }
        typing.remove(convId)
        automationDrafts[convId] = nil
        updateBadge()
        publishShareDirectory()
    }

    func markRead(_ convId: String, explicit: Bool) {
        guard let conversation = conversations[convId], let latest = conversation.latestReply else { return }
        let held = conversation.read
        let unread = explicit ? false : held?.unread == true
        let ahead = latest.ts > conversation.readUpTo
        guard ahead || held?.unread != unread else { return }
        setRead(ReadCursor(convId: convId, messageId: ahead ? latest.id : held!.messageId,
            ts: ahead ? latest.ts : held!.ts, unread: unread), in: conversation)
    }

    func markUnread(_ convId: String) {
        guard let conversation = conversations[convId], var cursor = conversation.read, !cursor.unread else { return }
        cursor.unread = true
        setRead(cursor, in: conversation)
    }

    private func setRead(_ cursor: ReadCursor, in conversation: Conversation) {
        var conversation = conversation
        conversation.read = cursor
        conversation.readPending = true
        store(conversation)
        transmit(.readCursor(cursor))
        if !isDemo, !cursor.unread { Notices.removeDelivered(convId: cursor.convId, readUpTo: cursor.ts) }
    }

    private func receive(_ cursor: ReadCursor) {
        if !isDemo, !cursor.unread { Notices.removeDelivered(convId: cursor.convId, readUpTo: cursor.ts) }
        guard var conversation = conversations[cursor.convId] else {
            unplacedReads[cursor.convId] = cursor
            return
        }
        if conversation.readPending == true, let mine = conversation.read {
            if cursor.ts >= mine.ts && cursor.unread == mine.unread {
                conversation.readPending = nil
                conversation.read = cursor
            } else if cursor.ts > mine.ts {
                conversation.read = ReadCursor(convId: cursor.convId, messageId: cursor.messageId, ts: cursor.ts, unread: mine.unread)
            }
        } else {
            conversation.read = cursor
        }
        guard conversation != conversations[cursor.convId] else { return }
        store(conversation)
    }

    private func transmit(_ event: WireEvent) {
        guard let connection else { return }
        let generation = connectionGeneration
        Task {
            guard generation == connectionGeneration else { return }
            await connection.send(event)
        }
    }

    private func updateBadge() {
        guard !isDemo else { return }
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

extension RelayConnection.State {
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

struct InAppNotice: Equatable, Identifiable {
    let id = UUID()
    let convId: String
    let title: String
    let text: String
}
