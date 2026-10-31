import AppIntents
import Foundation

/// Where a widget, a control or a Lock Screen accessory opens the app.
enum WidgetLink: Equatable, Sendable {
    case conversation(String)
    case new
    /// A new conversation with the keyboard up.
    case ask
    /// A new conversation with dictation started.
    case talk

    private static let scheme = "yorozu"
    private static let host = "widget"

    var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = Self.host
        parts.path = switch self {
        case .conversation(let id): "/conversation/\(id)"
        case .new: "/new"
        case .ask: "/ask"
        case .talk: "/talk"
        }
        return parts.url!
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host() == Self.host else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch (path.first, path.count) {
        case ("conversation", 2): self = .conversation(path[1])
        case ("new", 1): self = .new
        case ("ask", 1): self = .ask
        case ("talk", 1): self = .talk
        default: return nil
        }
    }
}

/// Hands a link to the app. The intents below open the app when run, so `perform` runs in the app,
/// where the app delegate installed `handler`; the widget extension never handles one itself.
@MainActor
enum WidgetRouter {
    static var handler: ((WidgetLink) -> Void)? {
        didSet { if let handler, let waiting = pending { pending = nil; handler(waiting) } }
    }
    private static var pending: WidgetLink?

    static func open(_ link: WidgetLink) {
        if let handler { handler(link) } else { pending = link }
    }
}

struct NewConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "New Conversation"
    static let description = IntentDescription("Opens a new conversation in Yorozu.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await WidgetRouter.open(.new)
        return .result()
    }
}

struct AskInYorozuIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask in Yorozu"
    static let description = IntentDescription("Opens a new conversation in Yorozu with the keyboard up.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await WidgetRouter.open(.ask)
        return .result()
    }
}

struct TalkToYorozuIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Yorozu"
    static let description = IntentDescription("Opens a new conversation in Yorozu and starts voice input.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await WidgetRouter.open(.talk)
        return .result()
    }
}
