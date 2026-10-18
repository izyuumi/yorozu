import AppIntents
import CoreSpotlight
import YorozuWire

// Siri, Shortcuts and Spotlight (owner, 2026-10-17): ask the agent and hear its reply, open a conversation, start one.
// The model is the app delegate's, registered with `AppDependencyManager` at launch (V3Push.swift).

/// A conversation, by its title, for Siri to name and Shortcuts to pick, and, with its recent text, in the on-device
/// Spotlight index Siri searches (``SpotlightIndexer``; owner, 2026-10-17).
struct ConversationEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = ConversationQuery()

    /// The messages Siri and Spotlight see: the newest, as "You:" and "Yorozu:" lines, at most this many characters.
    static let indexedCharacters = 4_000

    let id: String
    let title: String
    /// The conversation's recent messages, newest last.
    let recentText: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .text)
        set.title = title
        set.displayName = title
        set.contentDescription = recentText
        set.textContent = recentText
        return set
    }

    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.displayTitle
        let lines = conversation.items.filter { ($0.kind == .user || $0.kind == .agent) && !$0.summary.isEmpty }
            .map { ($0.kind == .user ? "You: " : "Yorozu: ") + $0.summary }
        recentText = String(lines.joined(separator: "\n").suffix(Self.indexedCharacters))
    }

    /// The lines that contain `query`, for a search's answer.
    func lines(matching query: String) -> [String] {
        recentText.split(separator: "\n").map(String.init).filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct ConversationQuery: EntityStringQuery {
    @Dependency private var model: V3Model

    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        await MainActor.run { model.isDemo ? [] : identifiers.compactMap { model.conversations[$0].map(ConversationEntity.init) } }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        await MainActor.run { model.isDemo ? [] : model.search(string).map(ConversationEntity.init) }
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        await MainActor.run { recent() }
    }

    /// The list's conversations, newest first, archived ones left out.
    @MainActor private func recent() -> [ConversationEntity] {
        guard !model.isDemo else { return [] }
        return model.conversations.values.filter { $0.archived != true }.sorted { $0.updatedAt > $1.updatedAt }
            .prefix(50).map(ConversationEntity.init)
    }
}

/// Sends a message and returns the agent's reply, which Siri reads out. A run longer than the wait still finishes: its
/// reply arrives as the usual notification.
struct AskYorozuIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Yorozu"
    static let description = IntentDescription("Sends a message to your agent and returns its reply.")

    @Parameter(title: "Message", requestValueDialog: "What should I ask?")
    var message: String
    @Parameter(title: "Conversation", description: "A new conversation when left empty.")
    var conversation: ConversationEntity?

    @Dependency private var model: V3Model

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Yorozu \(\.$message)") { \.$conversation }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let (value, dialog): (String, IntentDialog) = switch try await model.ask(message, in: conversation?.id) {
        case .reply(let text): (text, IntentDialog("\(text)"))
        case .pending: ("", IntentDialog("Sent. The reply will come as a notification."))
        }
        return .result(value: value, dialog: dialog)
    }
}

struct OpenConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a conversation in Yorozu.")
    static let openAppWhenRun = true

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    @Dependency private var model: V3Model

    func perform() async throws -> some IntentResult {
        let id = conversation.id
        await MainActor.run { if !model.isDemo { model.requestedConversation = id } }
        return .result()
    }
}

struct NewConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "New Conversation"
    static let description = IntentDescription("Opens a new conversation in Yorozu.")
    static let openAppWhenRun = true

    @Dependency private var model: V3Model

    func perform() async throws -> some IntentResult {
        await MainActor.run { if !model.isDemo { model.requestedConversation = V3Event.newId() } }
        return .result()
    }
}

/// Ready without setup, in Siri and Spotlight. Japanese phrases are in AppShortcuts.xcstrings.
struct YorozuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskYorozuIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something"],
            shortTitle: "Ask Yorozu", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: OpenConversationIntent(), phrases: ["Open \(\.$conversation) in \(.applicationName)"],
            shortTitle: "Open Conversation", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: SearchYorozuIntent(), phrases: ["Search \(.applicationName)", "Find in \(.applicationName)"],
            shortTitle: "Search Yorozu", systemImageName: "magnifyingglass")
        AppShortcut(intent: NewConversationIntent(),
            phrases: ["New \(.applicationName) conversation", "Start a conversation in \(.applicationName)"],
            shortTitle: "New Conversation", systemImageName: "square.and.pencil")
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notPaired, agent(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: "Yorozu isn’t paired with a host yet. Open Yorozu to pair it."
        case .agent(let message): "The agent couldn’t answer: \(message)"
        }
    }
}

extension V3Model {
    enum AskOutcome { case reply(String), pending }

    /// Sends `text` (into a new conversation when `convId` is nil) and waits for the run's reply: the reply items that
    /// were not there before, once the agent has stopped typing. `pending` past `timeout`.
    func ask(_ text: String, in convId: String?, timeout: Duration = .seconds(25)) async throws -> AskOutcome {
        guard !isDemo, pairing != nil else { throw IntentFailure.notPaired }
        let convId = convId ?? V3Event.newId()
        let answers: (Conversation?) -> [ChatItem] = { $0?.items.filter { $0.kind == .agent || $0.kind == .error } ?? [] }
        let before = Set(answers(conversations[convId]).map(\.id))
        send(text, in: convId)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            let new = answers(conversations[convId]).filter { !before.contains($0.id) }
            guard !new.isEmpty, !typing.contains(convId) else { continue }
            if let error = new.first(where: { $0.kind == .error }) { throw IntentFailure.agent(error.text) }
            return .reply(new.map(\.text).joined(separator: "\n\n"))
        }
        return .pending
    }
}

/// Finds conversations by what was said in them, for Siri to answer from: the matching lines, newest conversation first.
struct SearchYorozuIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Yorozu"
    static let description = IntentDescription("Finds conversations that mention something, with the lines that match.")

    @Parameter(title: "Search For", requestValueDialog: "What should I look for?")
    var query: String

    @Dependency private var model: V3Model

    static var parameterSummary: some ParameterSummary { Summary("Search Yorozu for \(\.$query)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[ConversationEntity]> & ProvidesDialog {
        let query = query
        let found = await MainActor.run { model.isDemo ? [] : model.search(query).prefix(5).map(ConversationEntity.init) }
        guard !found.isEmpty else { return .result(value: [], dialog: "Nothing in Yorozu mentions “\(query)”.") }
        let answer = found.map { conversation in
            ([conversation.title] + conversation.lines(matching: query).suffix(3)).joined(separator: "\n")
        }.joined(separator: "\n\n")
        return .result(value: Array(found), dialog: "\(answer)")
    }
}

extension V3Model {
    /// Conversations whose title or messages contain `query`, newest first, archived ones left out.
    func search(_ query: String) -> [Conversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return conversations.values.filter { conversation in
            conversation.archived != true && (conversation.displayTitle.localizedCaseInsensitiveContains(query)
                || conversation.items.contains { $0.summary.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// Keeps the on-device Spotlight index (what Siri searches) in step with the conversations: each changed one again,
/// a deleted or archived one out, all of them out when unpaired or when Settings turns it off. A separate index under
/// Data Protection `complete` on iPhone and iPad, like the cache: searchable only after the device is unlocked.
@MainActor
final class SpotlightIndexer {
    static let enabledKey = "spotlightIndexing"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private(set) static var shared: SpotlightIndexer?

    private let model: V3Model
    #if os(iOS)
    private let index = CSSearchableIndex(name: "conversations", protectionClass: .complete)
    #else
    private let index = CSSearchableIndex(name: "conversations")
    #endif
    /// What was last indexed, by conversation: its title, newest item and count, to skip the unchanged.
    private var indexed: [String: String]?

    static func start(model: V3Model) {
        guard shared == nil else { return }
        let indexer = SpotlightIndexer(model: model)
        shared = indexer
        Task { await indexer.run() }
    }

    private init(model: V3Model) { self.model = model }

    private func run() async {
        while true {
            await sync()
            await withCheckedContinuation { done in
                withObservationTracking { _ = model.conversations; _ = model.pairing; _ = model.isDemo } onChange: { done.resume() }
            }
            // A burst of history pages or a streamed reply, indexed once.
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func sync() async {
        // Keep the real index untouched while the in-memory sample conversations are visible.
        guard !model.isDemo else { return }
        guard Self.enabled, model.pairing != nil else {
            if indexed != [:] { try? await index.deleteAllSearchableItems() }
            indexed = [:]
            return
        }
        let current = model.conversations.values.filter { $0.archived != true }
        let marks = Dictionary(uniqueKeysWithValues: current.map {
            ($0.id, "\($0.displayTitle)|\($0.items.last?.id ?? "")|\($0.items.count)")
        })
        let changed = current.filter { indexed?[$0.id] != marks[$0.id] }.map(ConversationEntity.init)
        let gone = Array(Set((indexed ?? [:]).keys).subtracting(marks.keys))
        do {
            if !changed.isEmpty { try await index.indexAppEntities(changed) }
            if !gone.isEmpty { try await index.deleteAppEntities(identifiedBy: gone, ofType: ConversationEntity.self) }
            indexed = marks
        } catch {
            // Tried again on the next change.
        }
    }
}
