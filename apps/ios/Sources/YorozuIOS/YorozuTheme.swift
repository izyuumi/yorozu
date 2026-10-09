import SwiftUI
import UIKit

// The system look (#311): system backgrounds, materials and standard bars, with Yorozu's vermilion
// accent and a few state colours. Every colour has an explicit dark counterpart.

enum YorozuPalette {
    /// The accent: tint, links, labels.
    static let vermilion = adaptive(
        light: (0.737, 0.176, 0.110),
        dark: (0.941, 0.376, 0.278)
    )
    /// The user's bubble behind white text: darker than the accent in dark mode, so the text holds 4.5:1.
    static let bubble = adaptive(
        light: (0.737, 0.176, 0.110),
        dark: (0.722, 0.220, 0.165)
    )
    static let sage = adaptive(
        light: (0.243, 0.482, 0.227),
        dark: (0.561, 0.749, 0.514)
    )
    /// Amber for a state that needs attention without being an error: an offline Mac, a failed task,
    /// an over-long draft. Darker than the system orange so it holds 4.5:1 as text.
    static let warning = adaptive(
        light: (0.604, 0.322, 0.000),
        dark: (0.941, 0.639, 0.251)
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

extension View {
    /// A grouped card in the system's secondary fill.
    func yorozuCard(
        padding: CGFloat = LayoutMetrics.cardPadding,
        radius: CGFloat = LayoutMetrics.cardRadius
    ) -> some View {
        self.padding(padding)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Liquid Glass on iOS 26, the regular material before it.
    @ViewBuilder func yorozuGlass(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// A bar along the bottom edge: content scrolls under it with the system's edge effect on
    /// iOS 26, over the bar material before it.
    @ViewBuilder func yorozuBottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { content().background(.bar) }
        }
    }

    /// The system subtitle under the navigation title on iOS 26; nothing before it.
    @ViewBuilder func navigationSubtitleIfAvailable(_ text: String) -> some View {
        if #available(iOS 26, *) {
            navigationSubtitle(text)
        } else {
            self
        }
    }

    /// Applies Yorozu's action colour without replacing semantic warning/error colours.
    func yorozuTint() -> some View {
        tint(YorozuPalette.vermilion)
    }
}
