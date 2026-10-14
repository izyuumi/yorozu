import Foundation
import ProjectXCore

/// Unsent drafts on this Mac (#405): the popover's (the Main chat's or Quick Chat's), each chat's and every New chat not
/// sent yet, with their files, across relaunches; never synced. Files Yorozu made (pasted or dropped data) live under
/// `DraftFile.scratchRoot` while a draft keeps them; files picked in Finder stay where they are.
@MainActor final class MacDrafts: ObservableObject {
    struct File: Codable, Equatable { var path: String; var temporary: Bool; var sendOriginal: Bool }
    struct Saved: Codable, Equatable {
        var text = ""
        var files: [File] = []
        var replyTo: String?
        var updated = Date().timeIntervalSince1970
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty && replyTo == nil }
    }
    @Published private(set) var all: [String: Saved] = [:]
    private var saveTask: Task<Void,Never>?
    private let url = URL.applicationSupportDirectory.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "to.yumi.yorozu")/drafts.json")

    /// Reads the drafts and removes scratch files none of them keeps.
    func load() {
        all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Saved].self,from: $0) } ?? [:]
        let kept = Set(all.values.flatMap(\.files).filter(\.temporary).map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent })
        for dir in (try? FileManager.default.contentsOfDirectory(at: DraftFile.scratchRoot,includingPropertiesForKeys: nil)) ?? [] where !kept.contains(dir.lastPathComponent) {
            try? FileManager.default.removeItem(at: dir)
        }
        // The old scratch folder under $TMPDIR held no draft.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Yorozu-attachments",isDirectory: true))
    }

    func saved(_ key: String) -> Saved { all[key] ?? Saved() }

    /// The composer's files as they were, those still on disk.
    func files(_ key: String) -> [DraftFile] {
        saved(key).files.compactMap { f in
            var d = DraftFile(url: URL(fileURLWithPath: f.path),temporary: f.temporary); d?.sendOriginal = f.sendOriginal; return d
        }
    }

    func update(_ key: String,text: String,files: [DraftFile] = [],replyTo: String? = nil) {
        var next = Saved(text: text,files: files.map { File(path: $0.url.path,temporary: $0.temporary,sendOriginal: $0.sendOriginal) },replyTo: replyTo)
        if let old = all[key], old.text == next.text, old.files == next.files, old.replyTo == next.replyTo { next.updated = old.updated }
        let value = next.isEmpty ? nil : next
        guard all[key] != value else { return }
        all[key] = value
        scheduleSave()
    }

    /// Sent (its files went with it) or discarded (Yorozu's own files go too).
    func clear(_ key: String,discardFiles: Bool = false) {
        guard let old = all.removeValue(forKey: key) else { return }
        if discardFiles { old.files.filter(\.temporary).forEach { DraftFile.discard(URL(fileURLWithPath: $0.path)) } }
        scheduleSave()
    }

    /// New chat drafts with something in them, newest first.
    var newChats: [(id: String,draft: Saved)] {
        all.compactMap { key,draft in key.hasPrefix("new:") ? (String(key.dropFirst(4)),draft) : nil }.sorted { $0.draft.updated > $1.draft.updated }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel(); saveTask = nil
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        try? data.write(to: url,options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: url.path)
    }
}

extension AppModel {
    /// The popover composer's draft key: the Main chat's while it is on, else Quick Chat's.
    var popoverDraftKey: String { mainChat ? Drafts.chat(Store.mainID) : Drafts.quick }

    func savePopoverDraft() {
        guard !restoringDraft else { return }
        drafts.update(popoverDraftKey,text: draft,files: files,replyTo: replyingTo?.id)
    }

    /// The popover's composer from its saved draft: at launch and whenever the Main chat is turned on or off.
    func restorePopoverDraft() {
        restoringDraft = true; defer { restoringDraft = false }
        let saved = drafts.saved(popoverDraftKey)
        draft = saved.text; files = drafts.files(popoverDraftKey)
        replyingTo = saved.replyTo.flatMap { id in snapshot.messages.first { $0.id == id } }
    }

    /// Quick Chat closed: a sent one starts fresh next time; an unsent draft stays to be resumed.
    func quickChatClosed() {
        guard quickSent else { return }
        quickSent = false
        quickThread = UUID().uuidString.lowercased()
    }

    /// Quick Chat's Discard: the draft and Yorozu's own files go, and the next opening starts fresh.
    func discardQuickChat() {
        files.filter(\.temporary).forEach { DraftFile.discard($0.url) }
        restoringDraft = true; draft = ""; files = []; replyingTo = nil; restoringDraft = false
        drafts.clear(Drafts.quick)
        quickSent = false
        quickThread = UUID().uuidString.lowercased()
    }
}
