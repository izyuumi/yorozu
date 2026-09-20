import SwiftUI

/// The provenance of the small provider identifier. These are deliberately not Yorozu branding.
public enum AgentMark: String, Equatable, Sendable {
    case yorozu
    case claude
    case openAI
}

/// Provider-owned marks used only beside the agent they identify. The supplied artwork is shown
/// in its original colors and aspect ratio: Claude's official orange mark, and OpenAI's official
/// black/white Blossom with the clear space built into the distributed asset.
public struct AgentMarkView: View {
    private let agent: ThreadAgent

    public init(_ agent: ThreadAgent) {
        self.agent = agent
    }

    public var body: some View {
        Group {
            switch agent.mark {
            case .yorozu:
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            case .claude:
                Image("ClaudeMark", bundle: .module)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            case .openAI:
                Image("OpenAIBlossom", bundle: .module)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    // The official file includes prescribed clear space around the Blossom.
                    .frame(width: 24, height: 24)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// A compact, accessible identity for a coding-agent row. Codex keeps the OpenAI company mark
/// paired with its product name because OpenAI does not publish a separate Codex product icon.
public struct AgentIdentifierView: View {
    private let agent: ThreadAgent

    public init(_ agent: ThreadAgent) {
        self.agent = agent
    }

    public var body: some View {
        HStack(spacing: 2) {
            AgentMarkView(agent)
            if agent.markRequiresProductName {
                Text(agent.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.label)
    }
}

/// Shared wording for the existing iOS and macOS Settings surfaces.
public enum ProviderMarkAttribution {
    public static let notice = String(localized:
        "Claude and Claude Code are trademarks of Anthropic, PBC. OpenAI and Codex are trademarks of OpenAI. Their marks identify the selected agent only; Yorozu is independent and is not affiliated with or endorsed by either provider."
    )
}
