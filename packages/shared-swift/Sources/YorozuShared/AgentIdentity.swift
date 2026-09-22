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
    private let size: CGFloat

    /// `size` is the drawn glyph, the same for every mark, so rows line up whichever agent owns them.
    public init(_ agent: ThreadAgent, size: CGFloat = 16) {
        self.agent = agent
        self.size = size
    }

    public var body: some View {
        Group {
            switch agent.mark {
            case .yorozu:
                YorozuMark(dimension: size)
            case .claude:
                Image("ClaudeMark", bundle: .module)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            case .openAI:
                // The official file carries clear space: the Blossom fills about half its canvas,
                // so the canvas is drawn at twice the size and left to overflow the frame.
                Image("OpenAIBlossom", bundle: .module)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: size * 2, height: size * 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A compact, accessible identity for a coding-agent row: the mark alone, with the agent's name
/// for VoiceOver.
public struct AgentIdentifierView: View {
    private let agent: ThreadAgent
    private let size: CGFloat

    public init(_ agent: ThreadAgent, size: CGFloat = 16) {
        self.agent = agent
        self.size = size
    }

    public var body: some View {
        AgentMarkView(agent, size: size)
            // Sit the mark on the text's baseline the way a capital does, not above it.
            .alignmentGuide(.firstTextBaseline) { $0.height * 0.8 }
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
