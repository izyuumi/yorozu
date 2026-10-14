import Foundation
import Observation

/// Unsent drafts on this device (#405): each chat's composer, every New chat not sent yet and Quick Chat's, with their
/// files, kept across relaunches and never synced to other devices. A draft becomes a conversation only when its first
/// message is sent. One JSON file in `Application Support/Drafts/`, protected like the outbox; files stay in
/// `StagedFile.drafts` while a draft refers to them.
@MainActor
@Observable
final class Drafts {
    struct Draft: Codable, Equatable {
        var text = ""
        var files: [StagedFile] = []
        /// The message a reply quotes, in a chat that takes replies.
        var replyTo: String?
        /// Last edited, epoch ms: where a New chat draft sits in the list.
        var updated = 0

        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty && replyTo == nil }
    }

    /// Keys: `chat:<thread id>` (or `chat:main`), `new:<thread id>` for a New chat whose first message creates that thread,
    /// and `quick` for the Mac's Quick Chat while the Main chat is off.
    static func chat(_ id: String) -> String { "chat:\(id)" }
    static func new(_ id: String) -> String { "new:\(id)" }
    static let quick = "quick"

    private(set) var all: [String: Draft] = [:]
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let file = ProtectedFile(folder: "Drafts", name: "drafts.json")

    private struct Saved: Codable {
        var owner: String
        var drafts: [String: Draft]
    }

    /// The drafts of this pairing; another pairing's are dropped with their files. Staged files no draft keeps go.
    /// `adoptFrom`: a Repair of the same host keeps the drafts the previous identity (that owner) left; any other owner's
    /// stay unread. False when adopting drafts could not be written yet (the caller tries again at the next launch).
    @discardableResult
    func load(owner: String, adoptFrom: String? = nil) -> Bool {
        self.owner = owner
        let saved = file.load(Saved.self)
        let adopting = saved != nil && saved?.owner == adoptFrom
        all = saved?.owner == owner || adopting ? saved?.drafts ?? [:] : [:]
        if adopting, !saveNow() { return false }
        // A file the system removed (or a draft from an older build) drops out rather than failing the send.
        for (key, draft) in all { all[key]?.files = draft.files.filter(\.exists) }
        StagedFile.prune(keeping: Set(all.values.flatMap(\.files).map(\.id)))
        return true
    }

    /// Remove host: every draft and its files.
    func wipe() {
        all = [:]
        owner = nil
        file.wipe()
        StagedFile.clearAll()
    }

    func draft(_ key: String) -> Draft { all[key] ?? Draft() }

    /// Saves the composer as it is now; an empty one is no draft. Files a draft no longer lists are removed.
    func update(_ key: String, text: String, files: [StagedFile], replyTo: String? = nil) {
        let old = all[key]
        var draft = Draft(text: text, files: files, replyTo: replyTo, updated: Int(Date().timeIntervalSince1970 * 1000))
        if let old, old.text == text, old.files == files, old.replyTo == replyTo { draft.updated = old.updated }
        let kept = Set(files.map(\.id))
        old?.files.filter { !kept.contains($0.id) && !others(key).contains($0.id) }.forEach { $0.discard() }
        all[key] = draft.isEmpty ? nil : draft
        if old != all[key] { scheduleSave() }
    }

    /// Sent: the draft goes, its files already moved to the outbox. Discarded: the files go too.
    func clear(_ key: String, discardFiles: Bool = false) {
        guard let old = all.removeValue(forKey: key) else { return }
        if discardFiles { old.files.filter { !others(key).contains($0.id) }.forEach { $0.discard() } }
        scheduleSave()
    }

    /// Files other drafts still refer to: never removed for this one.
    private func others(_ key: String) -> Set<UUID> { Set(all.filter { $0.key != key }.values.flatMap(\.files).map(\.id)) }

    /// New chat drafts with something in them, newest first: the list shows them so they can be picked up again.
    var newChats: [(id: String, draft: Draft)] {
        all.compactMap { key, draft in key.hasPrefix("new:") ? (String(key.dropFirst(4)), draft) : nil }.sorted { $0.draft.updated > $1.draft.updated }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Sent: the draft goes now, on disk too, before its files are removed (#405). False when that write failed: the
    /// caller keeps its record of the send until a later write succeeds, so the draft cannot come back.
    @discardableResult
    func consume(_ key: String) -> Bool {
        guard all.removeValue(forKey: key) != nil else { return true }
        return saveNow()
    }

    /// Drafts the outbox says were sent but whose removal did not reach the disk (a crash, a full disk): the draft at that
    /// key is dropped when it is not newer than the sent revision; a later edit stays.
    func dropSent(_ sent: [(key: String, stamp: Int)]) {
        let gone = sent.filter { s in all[s.key].map { $0.updated <= s.stamp } == true }
        guard !gone.isEmpty else { return }
        gone.forEach { all[$0.key] = nil }
        saveNow()
    }

    /// Written now; true once on disk. Before a send, so the revision on disk is the one the outbox records.
    @discardableResult
    func saveNow() -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard let owner else { return false }
        return file.saveNow(Saved(owner: owner, drafts: all))
    }

    /// Now: before the app goes to the background or a link navigates away.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let owner else { return }
        file.save(Saved(owner: owner, drafts: all))
    }
}
