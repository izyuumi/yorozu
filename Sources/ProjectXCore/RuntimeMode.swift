import Foundation

/// User-visible mode must remain unmistakable even when status/error notices change.
public enum RuntimeMode: String, Sendable {
    case offline, fixture, live
    public static func from(_ environment: [String:String]) -> Self {
        Self(rawValue: environment["PROJECTX_MODE"] ?? "live") ?? .offline
    }
    public var windowTitle: String {
        switch self {
        case .fixture: return "Yorozu — TEST FIXTURE (no AI)"
        case .offline: return "Yorozu — OFFLINE (no AI)"
        case .live: return "Yorozu"
        }
    }
    public var bannerTitle: String {
        switch self {
        case .fixture: return "TEST FIXTURE — NO AI / NO LLM"
        case .offline: return "OFFLINE — NO AI CONNECTED"
        case .live: return "LIVE — local OpenClaw Gateway, projectx agent"
        }
    }
    public var explanation: String {
        switch self {
        case .fixture: return "For synthetic workflow testing only. Replies are scripted test output, not AI answers. Do not use this window for real requests. Your fixture history is preserved separately."
        case .offline: return "This app is not connected to a model. Messages are saved locally only; it cannot answer or perform your requests. Offline mode was explicitly selected or the requested mode was invalid."
        case .live: return "Replies come from real models through the local OpenClaw Gateway (openclaw CLI, dedicated projectx agent). Messages, results and memory are saved locally. Changes to running work apply right after its current step."
        }
    }
    public var sendLabel: String {
        switch self { case .fixture: return "Send test message"; case .offline: return "Save offline"; case .live: return "Send" }
    }
    public func permitsInput(fixtureAcknowledged: Bool) -> Bool { self != .fixture || fixtureAcknowledged }
}
