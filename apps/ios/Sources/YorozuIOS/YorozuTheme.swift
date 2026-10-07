import SwiftUI
import UIKit

// From v1 packages/shared-swift YorozuTheme.swift: the palette, the tint and the paper card.

/// Yorozu's shared visual language: warm paper, charcoal ink, one vermilion action colour and
/// quiet sage for healthy state. Every colour has an explicit dark counterpart rather than
/// relying on a light surface to be dimmed.
enum YorozuPalette {
    static let canvas = adaptive(
        light: (0.973, 0.957, 0.918),
        dark: (0.105, 0.102, 0.090)
    )
    static let paper = adaptive(
        light: (1.000, 0.992, 0.969),
        dark: (0.145, 0.137, 0.118)
    )
    static let ink = adaptive(
        light: (0.145, 0.137, 0.118),
        dark: (0.953, 0.925, 0.863)
    )
    static let vermilion = adaptive(
        light: (0.737, 0.176, 0.110),
        dark: (0.941, 0.376, 0.278)
    )
    static let sage = adaptive(
        light: (0.349, 0.459, 0.325),
        dark: (0.588, 0.710, 0.549)
    )
    /// Amber for a state that needs attention without being an error: an offline Mac, a picture
    /// too big to send. Darker than the system orange so it holds 4.5:1 as text on paper.
    static let warning = adaptive(
        light: (0.604, 0.322, 0.000),
        dark: (0.941, 0.639, 0.251)
    )
    static let stone = adaptive(
        light: (0.875, 0.843, 0.788),
        dark: (0.263, 0.247, 0.216)
    )
    static let rule = adaptive(
        light: (0.824, 0.784, 0.718),
        dark: (0.310, 0.286, 0.247)
    )

    private static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(value.0), green: CGFloat(value.1), blue: CGFloat(value.2), alpha: 1)
        })
    }
}

private struct YorozuPaperCard: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(YorozuPalette.paper, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(YorozuPalette.rule.opacity(0.72), lineWidth: 0.75)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 1.5, y: 1)
    }
}

extension View {
    /// The paper-card treatment shared by thread rows, progress, work and action cards.
    func yorozuPaperCard(
        padding: CGFloat = LayoutMetrics.cardPadding,
        radius: CGFloat = LayoutMetrics.cardRadius
    ) -> some View {
        modifier(YorozuPaperCard(padding: padding, radius: radius))
    }

    /// Applies Yorozu's action colour without replacing semantic warning/error colours.
    func yorozuTint() -> some View {
        tint(YorozuPalette.vermilion)
    }
}
