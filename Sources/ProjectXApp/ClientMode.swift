import Foundation
import ProjectXCore
import YorozuWire

// A Mac in the client role (owner, 2026-10-11, as in v1): it runs no engine, harness or relay host of its own and uses
// another host Mac through the relay with the phone's client core (`PhoneModel`). What that core mirrors becomes the
// same `Snapshot` the host draws from its store, so the popover and Activities work unchanged.

extension Snapshot {
    /// The client's mirror, in the host's records. Wire times are epoch milliseconds; the store's are seconds.
    @MainActor init(client: PhoneModel) {
        self.init()
        topics = client.topics.values.sorted { $0.created < $1.created }
            .map { Topic(mirroredID: $0.id,label: $0.label,created: Double($0.created) / 1000,attachedTo: $0.attachedTo,summary: nil) }
        messages = client.bubbles.map { b in
            Message(mirroredID: b.id,role: b.user ? "user" : "assistant",body: b.text,topicID: b.topicId,taskID: b.taskId,replyTo: b.replyTo,
                    kind: b.kind ?? (b.failed ? "failure" : "conversation"),created: Double(b.ts) / 1000,
                    notice: b.notice.map { Notice(code: $0.code,params: $0.params) },
                    readAt: b.readAt.map { Double($0) / 1000 },sentAt: b.sentAt.map { Double($0) / 1000 })
        }
        work = client.tasks.values.sorted { $0.created < $1.created }.map { t in
            Work(mirroredID: t.id,topicID: t.topicId,messageID: t.messageId,instruction: t.instruction,state: t.state,revision: t.revision,
                 suppressed: t.suppressed,result: t.result,error: t.error,created: Double(t.created) / 1000,executor: t.executor)
        }
        events = client.workerEvents.values.sorted { $0.created < $1.created }
            .map { WorkerEvent(mirroredID: $0.id,taskID: $0.taskId,kind: $0.kind,body: $0.body,created: Double($0.created) / 1000) }
        amendments = client.amendments.values.sorted { $0.revision < $1.revision }
            .map { Amendment(mirroredID: $0.id,taskID: $0.taskId,messageID: $0.messageId,revision: $0.revision,instruction: $0.instruction,state: $0.state) }
    }
}

extension Readiness {
    /// The host's readiness as it syncs it; the fixes are on the host, so none is offered here.
    init(host data: ReadinessData) {
        self.init(items: data.items.map { item in
            let severity: Item.Severity = switch item.severity { case .ok: .ok; case .warning: .warning; case .blocking: .blocking }
            return Item(id: item.id,title: item.title,detail: item.fix.map { String(localized: "Fix this on the host: \($0)") } ?? "",severity: severity)
        })
    }
}

extension AppModel {
    var isClient: Bool { client != nil }

    /// Client role: the pairing (Keychain) dials at once; the mirror is read into `snapshot` like the host's store poll.
    func startClient() {
        let client = PhoneModel()
        self.client = client
        client.resume()
        ready = true; status = nil
        clientPoll = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshFromClient()
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    func refreshFromClient() {
        guard let client else { return }
        let next = Snapshot(client: client)
        if next != snapshot { snapshot = next }
        let hostRouting = client.routing == true; if hostRouting != routing { routing = hostRouting }
        if client.readCursor?.messageId != readCursor { readCursor = client.readCursor?.messageId }
        if client.jobTopicIds != jobTopics { jobTopics = client.jobTopicIds }
        let hostReadiness = client.readiness.map(Readiness.init(host:))
        if hostReadiness != readiness { readiness = hostReadiness }
        // Off the link the host's work state is unknown, never idle (as on the phone).
        let line: String? = client.hasPairing
            ? (client.shownStatus == .connected ? nil : client.updateRequired ?? String(localized: "\(client.shownStatus.label) · Status unknown"))
            : String(localized: "Not paired with a host yet: Settings › Host.")
        if line != status { status = line }
    }

    /// The task card's Stop and Retry, on the host's engine or, from a client, over the relay as `task_control`.
    func control(task id: String, _ action: TaskControlData.Action) async {
        if let client { _ = await client.control(id,action); return }
        guard let engine else { return }
        switch action {
        case .stop: _ = await engine.stopTask(id: id)
        case .retry: _ = await engine.retryTask(id: id)
        }
    }

    /// Sends the draft through the client's outbox (text only for now: files go from the phone or the host).
    func sendFromClient() {
        guard let client else { return }
        client.draft = draft
        client.replyingTo = replyingTo?.id
        client.send()
        if client.draft.isEmpty { draft = ""; replyingTo = nil }
    }
}
