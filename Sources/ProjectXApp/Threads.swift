import Foundation
import ProjectXCore
import YorozuWire

// Threads (owner, 2026-10-13): the chat window's list, sends and thread actions, on the host's engine or, from a client
// Mac, over the relay through the client core (`threads-v1`).

/// Where the chat window should go: a thread (nil: Main) and, optionally, a message to scroll to and ring.
struct ChatFocus: Equatable { var thread: String?; var message: String? }

extension ThreadRow {
    /// A row of a client's list, in the host's records. Wire times are epoch milliseconds.
    init(client d: ThreadData) {
        var t = Topic(mirroredID: d.id,label: d.name,created: Double(d.created) / 1000,attachedTo: nil,summary: d.summary)
        t.origin = d.origin; t.source = d.sourceMessageId; t.archivedAt = d.archivedAt.map { Double($0) / 1000 }; t.activity = Double(d.lastActivity) / 1000
        self.init(topic: t,state: d.state,lastMessageID: d.lastMessageId,unread: d.unread)
    }
}

extension AppModel {
    /// The whole list (#405), every page of it (a local query each), and the Main chat's row while it is on. A failed read
    /// keeps the rows held.
    func loadThreads(archived: Bool = false,more: Bool = false) async {
        if let client { await client.loadThreads(archived: archived,more: more); return } // rows arrive with the client poll
        guard let engine else { return }
        var rows: [ThreadRow] = [], after: String?
        repeat {
            guard let page = try? await engine.threads(archived: archived,after: after,limit: 200) else { return }
            rows += page.rows; after = page.next
        } while after != nil
        if archived { if rows != archivedThreads { archivedThreads = rows }; archivedNext = nil }
        else {
            if rows != threads { threads = rows }; threadsNext = nil
            let main = mainChat ? try? await engine.mainRow() : nil // archived or not: `chatRows` places it
            if main != mainThreadRow { mainThreadRow = main }
        }
    }

    /// The one chat list (#405): every thread and, while it is on, the Main chat, newest last visible message first, from
    /// the host's store or, on a client Mac, from the client core's cached rows.
    func chatRows(archived: Bool = false) -> [ChatRow] {
        if let client { return client.chatRows(archived: archived) }
        let ms = { (t: Double) in Int(t * 1000) }
        func row(_ r: ThreadRow) -> ChatRow {
            let preview = r.last.map { m in m.notice.map { NoticeText.text(code: $0.code,params: $0.params,fallback: m.body) } ?? m.body }
                .map { EngineBridge.excerpt($0) } ?? ""
            return ChatRow(id: r.topic.id,name: r.topic.label,preview: preview,time: ms(r.sortAt),dot: r.attention ? .attention : r.unread > 0 ? .unread : nil,
                           running: r.running,archived: r.topic.archivedAt != nil,openWork: r.openWork)
        }
        var rows = (archived ? archivedThreads : threads).filter { !jobTopics.contains($0.topic.id) }.map(row)
        // The Main chat is a row like any other (#405): its own name, and in the archived list once archived.
        let g = resolved?.config.general
        // A deleted Main chat leaves the list until its next message.
        if mainChat, (g?.mainChatArchived ?? false) == archived, let main = mainThreadRow, main.last != nil {
            var r = row(main); r.name = g.map { $0.mainChatName }.flatMap { $0.isEmpty ? nil : $0 } ?? ""; r.archived = archived; rows.append(r)
        }
        return rows.sorted(by: ChatRow.newestFirst)
    }

    /// The client core's lists, on each client poll.
    func syncClientThreads(_ client: PhoneModel) {
        let rows = client.threadList.map(ThreadRow.init(client:)), archived = client.archivedThreads.map(ThreadRow.init(client:))
        if rows != threads { threads = rows }
        if archived != archivedThreads { archivedThreads = archived }
        if client.threadsNext != threadsNext { threadsNext = client.threadsNext }
        if client.archivedNext != archivedNext { archivedNext = client.archivedNext }
    }

    /// One message typed in a thread. `id` names a thread the host may not have yet (New chat): its first message creates it.
    func send(_ text: String,thread id: String) async -> Bool {
        let new = !snapshot.topics.contains { $0.id == id }
        if let client { return client.send(text: text,files: [],thread: id,newThread: new) }
        guard let engine, runtimeMode.permitsInput(fixtureAcknowledged: fixtureAcknowledged) else { return false }
        await ensureModels()
        do {
            try await engine.send(text,thread: id,newThread: new)
            threadNotice = nil; snapshot = try await engine.snapshot(); await loadThreads()
            return true
        } catch { threadNotice = error.localizedDescription; return false }
    }

    /// Rename, archive, unarchive or delete. A client's refusal shows from `PhoneModel.threadRefusals`.
    func control(thread id: String,_ action: ThreadControlData.Action,name: String? = nil) async {
        if let client { await client.control(thread: id,action,name: name); return }
        guard let engine else { return }
        if id == Store.mainID {
            do { try await controlMain(action,name: name); threadNotice = nil } catch { threadNotice = error.localizedDescription }
            await loadThreads(); return
        }
        do {
            switch action {
            case .rename: try await engine.renameThread(id,to: name ?? "")
            case .archive: try await engine.archiveThread(id,true)
            case .unarchive: try await engine.archiveThread(id,false)
            case .delete: try await engine.deleteThread(id)
            case .stopAndDelete: try await engine.stopAndDeleteThread(id)
            }
            threadNotice = nil; snapshot = try await engine.snapshot()
        } catch { threadNotice = error.localizedDescription }
        await loadThreads()
        await loadThreads(archived: true)
    }

    /// The thread's read cursor moves to the newest message shown (forward only, in the Store).
    func markRead(_ id: String,thread: String) {
        if let client { Task { await client.markRead(id,thread: thread) }; return }
        guard let store else { return }
        Task { if (try? await store.markRead(thread: thread,message: id)) == true { await loadThreads() } }
    }

    /// A `yorozu://message/<id>` link (the secretary's citations) or a tapped notification: the message in its place. On the
    /// main timeline the popover or the window's Main scrolls to it; in a thread the chat window opens there.
    func open(message id: String) {
        guard let m = snapshot.messages.first(where: { $0.id == id }) else { status = String(localized: "That message is no longer here."); return }
        guard let thread = m.threadID else { focusMessageID = id; chatFocus = ChatFocus(thread: nil,message: id); return }
        chatFocus = ChatFocus(thread: thread,message: id); openChatWindow?()
    }

    /// Handles `yorozu://message/<id>`; other links open as usual.
    func openLink(_ url: URL) -> Bool {
        guard url.scheme == "yorozu", url.host() == "message", let id = url.pathComponents.last, id != "/" else { return false }
        open(message: id); return true
    }
}

extension ActivityState {
    /// From a thread row's current task state (the host's rule, without the task's result).
    init(current state: String?) {
        switch state {
        case "working","queued","amendment_pending": self = .running
        case "failed","uncertain","cancellation_requested": self = .attention
        case "done": self = .done
        default: self = .idle
        }
    }
}
