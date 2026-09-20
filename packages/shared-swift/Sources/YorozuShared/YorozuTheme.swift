import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Yorozu's shared visual language: warm paper, charcoal ink, one vermilion action colour and
/// quiet sage for healthy state. Every colour has an explicit dark counterpart rather than
/// relying on a light surface to be dimmed.
public enum YorozuPalette {
    public static let canvas = adaptive(
        light: (0.973, 0.957, 0.918),
        dark: (0.105, 0.102, 0.090)
    )
    public static let paper = adaptive(
        light: (1.000, 0.992, 0.969),
        dark: (0.145, 0.137, 0.118)
    )
    public static let ink = adaptive(
        light: (0.145, 0.137, 0.118),
        dark: (0.953, 0.925, 0.863)
    )
    public static let vermilion = adaptive(
        light: (0.737, 0.176, 0.110),
        dark: (0.941, 0.376, 0.278)
    )
    public static let sage = adaptive(
        light: (0.349, 0.459, 0.325),
        dark: (0.588, 0.710, 0.549)
    )
    public static let stone = adaptive(
        light: (0.875, 0.843, 0.788),
        dark: (0.263, 0.247, 0.216)
    )
    public static let rule = adaptive(
        light: (0.824, 0.784, 0.718),
        dark: (0.310, 0.286, 0.247)
    )

    private static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        #if canImport(UIKit)
            Color(uiColor: UIColor { traits in
                let value = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: CGFloat(value.0), green: CGFloat(value.1), blue: CGFloat(value.2), alpha: 1)
            })
        #elseif canImport(AppKit)
            Color(nsColor: NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                let value = match == .darkAqua ? dark : light
                return NSColor(red: CGFloat(value.0), green: CGFloat(value.1), blue: CGFloat(value.2), alpha: 1)
            })
        #else
            Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }
}

/// A small native-vector knot. The crossed loops echo the existing app icon without requiring
/// a raster asset in every surface; the vermilion centre remains legible at caption size.
public struct YorozuMark: View {
    private let dimension: CGFloat

    public init(dimension: CGFloat = 24) {
        self.dimension = dimension
    }

    public var body: some View {
        ZStack {
            loop.rotationEffect(.degrees(45))
            loop.rotationEffect(.degrees(-45))
            Circle()
                .fill(YorozuPalette.vermilion)
                .frame(width: dimension * 0.20, height: dimension * 0.20)
                .overlay(Circle().stroke(YorozuPalette.paper, lineWidth: max(1, dimension * 0.045)))
        }
        .frame(width: dimension, height: dimension)
        .accessibilityHidden(true)
    }

    private var loop: some View {
        RoundedRectangle(cornerRadius: dimension * 0.22, style: .continuous)
            .stroke(YorozuPalette.ink, lineWidth: max(1.25, dimension * 0.085))
            .frame(width: dimension * 0.40, height: dimension * 0.86)
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

public extension View {
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
