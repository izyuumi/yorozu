import Foundation

/// The provenance of the small provider identifier. These are deliberately not Yorozu branding.
public enum AgentMark: String, Equatable, Sendable {
    case yorozu
    case claude
    case openAI
    case generic
}
