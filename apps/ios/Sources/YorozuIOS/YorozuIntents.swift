import AppIntents
import YorozuWire

// Siri, Shortcuts and Spotlight (owner, 2026-10-17): ask the agent and hear its reply, open a conversation, start one.
// The model is the app delegate's, registered with `AppDependencyManager` at launch (V3Push.swift).

/// A conversation, by its title, for Siri to name and Shortcuts to pick.
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = ConversationQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.displayTitle
    }
}

struct ConversationQuery: EntityStringQuery {
    @Dependency private var model: V3Model

    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        await MainActor.run { identifiers.compactMap { model.conversations[$0].map(ConversationEntity.init) } }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        await MainActor.run { recent().filter { $0.title.localizedCaseInsensitiveContains(string) } }
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        await MainActor.run { recent() }
    }

    /// The list's conversations, newest first, archived ones left out.
    @MainActor private func recent() -> [ConversationEntity] {
        model.conversations.values.filter { $0.archived != true }.sorted { $0.updatedAt > $1.updatedAt }
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
        await MainActor.run { model.requestedConversation = id }
        return .result()
    }
}

struct NewConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "New Conversation"
    static let description = IntentDescription("Opens a new conversation in Yorozu.")
    static let openAppWhenRun = true

    @Dependency private var model: V3Model

    func perform() async throws -> some IntentResult {
        await MainActor.run { model.requestedConversation = V3Event.newId() }
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
        guard pairing != nil else { throw IntentFailure.notPaired }
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
