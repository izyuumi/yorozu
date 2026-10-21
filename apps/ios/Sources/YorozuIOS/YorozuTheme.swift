import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The system look (#311): system backgrounds, materials and standard bars, with the accent the user picked
// (vermilion by default) and a few state colours. Every colour has an explicit dark counterpart.

/// Light, dark, or the system's (owner, 2026-10-22).
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: Self { self }

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

/// The accent the user picked (owner, 2026-10-22): the tint, the user's bubble, the send control and the focus ring.
enum Accent: String, CaseIterable, Identifiable {
    case vermilion, pink, purple, indigo, blue, teal, green, graphite

    static let key = "accent"
    var id: Self { self }

    var name: String {
        switch self {
        case .vermilion: String(localized: "Vermilion")
        case .pink: String(localized: "Pink")
        case .purple: String(localized: "Purple")
        case .indigo: String(localized: "Indigo")
        case .blue: String(localized: "Blue")
        case .teal: String(localized: "Teal")
        case .green: String(localized: "Green")
        case .graphite: String(localized: "Graphite")
        }
    }

    /// Tint, links, labels: lighter in dark mode so it reads on a dark background.
    var tint: Color {
        switch self {
        case .vermilion: YorozuPalette.adaptive(light: (0.737, 0.176, 0.110), dark: (0.941, 0.376, 0.278))
        case .pink: YorozuPalette.adaptive(light: (0.761, 0.094, 0.357), dark: (0.957, 0.420, 0.573))
        case .purple: YorozuPalette.adaptive(light: (0.533, 0.200, 0.710), dark: (0.776, 0.537, 0.941))
        case .indigo: YorozuPalette.adaptive(light: (0.290, 0.310, 0.780), dark: (0.545, 0.561, 0.961))
        case .blue: YorozuPalette.adaptive(light: (0.000, 0.400, 0.820), dark: (0.302, 0.616, 1.000))
        case .teal: YorozuPalette.adaptive(light: (0.000, 0.455, 0.490), dark: (0.251, 0.773, 0.796))
        case .green: YorozuPalette.adaptive(light: (0.176, 0.490, 0.196), dark: (0.420, 0.796, 0.420))
        case .graphite: YorozuPalette.adaptive(light: (0.290, 0.290, 0.302), dark: (0.780, 0.780, 0.800))
        }
    }

    /// The user's bubble behind white text: darker than the tint in dark mode, so the text holds 4.5:1 in both.
    var bubble: Color {
        switch self {
        case .vermilion: YorozuPalette.adaptive(light: (0.737, 0.176, 0.110), dark: (0.722, 0.220, 0.165))
        case .pink: YorozuPalette.adaptive(light: (0.761, 0.094, 0.357), dark: (0.698, 0.110, 0.333))
        case .purple: YorozuPalette.adaptive(light: (0.533, 0.200, 0.710), dark: (0.490, 0.184, 0.651))
        case .indigo: YorozuPalette.adaptive(light: (0.290, 0.310, 0.780), dark: (0.345, 0.357, 0.800))
        case .blue: YorozuPalette.adaptive(light: (0.000, 0.400, 0.820), dark: (0.039, 0.400, 0.820))
        case .teal: YorozuPalette.adaptive(light: (0.000, 0.455, 0.490), dark: (0.000, 0.420, 0.455))
        case .green: YorozuPalette.adaptive(light: (0.176, 0.490, 0.196), dark: (0.165, 0.455, 0.180))
        case .graphite: YorozuPalette.adaptive(light: (0.290, 0.290, 0.302), dark: (0.345, 0.345, 0.360))
        }
    }
}

extension EnvironmentValues {
    /// The accent the user picked, for the colours `.tint` cannot stand in for (the bubble).
    @Entry var accent = Accent.vermilion
}

enum YorozuPalette {
    /// Amber for a state that needs attention without being an error: an offline Mac, a failed task,
    /// an over-long draft. Darker than the system orange so it holds 4.5:1 as text.
    static let warning = adaptive(
        light: (0.604, 0.322, 0.000),
        dark: (0.941, 0.639, 0.251)
    )

    static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat(value.0), green: CGFloat(value.1), blue: CGFloat(value.2), alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(value.0), green: CGFloat(value.1), blue: CGFloat(value.2), alpha: 1)
        })
        #endif
    }
}

extension View {
    /// One row of a scrolling column: its gutter, prose stopped at the reading width, centred in the scroll view's full
    /// width (a no-op on a phone). Each row is centred rather than the column: with `scrollTargetLayout`, a
    /// `ScrollPosition` scroll lines the target layout's leading edge up with the view's, which on an iPad shifted a
    /// centred column to the left edge.
    func readableRow(gutter: CGFloat = LayoutMetrics.gutter) -> some View {
        padding(.horizontal, gutter)
            .frame(maxWidth: LayoutMetrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    /// Liquid Glass on iOS 26, the regular material before it.
    @ViewBuilder func yorozuGlass(in shape: some Shape) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// A bar along the bottom edge: content scrolls under it with the system's edge effect on
    /// iOS 26, over the bar material before it.
    @ViewBuilder func yorozuBottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26, macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { content().background(.bar) }
        }
    }

    /// The system subtitle under the navigation title on iOS 26; nothing before it.
    @ViewBuilder func navigationSubtitleIfAvailable(_ text: String) -> some View {
        if #available(iOS 26, macOS 26, *) {
            navigationSubtitle(text)
        } else {
            self
        }
    }

    /// Applies the accent the user picked without replacing semantic warning/error colours.
    func yorozuTint() -> some View { modifier(YorozuTint()) }

    /// Light, dark or the system's, as picked in Settings: for a window's root.
    func yorozuAppearance() -> some View { modifier(YorozuAppearance()) }
}

private struct YorozuTint: ViewModifier {
    @AppStorage(Accent.key) private var accent = Accent.vermilion

    func body(content: Content) -> some View {
        content.tint(accent.tint).environment(\.accent, accent)
    }
}

private struct YorozuAppearance: ViewModifier {
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    func body(content: Content) -> some View {
        #if os(macOS)
        // On the Mac `preferredColorScheme(nil)` does not hand a window back to the system: the app's appearance does.
        content.onChange(of: appearance, initial: true) { _, appearance in
            NSApp.appearance = switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
        #else
        content.preferredColorScheme(scheme)
        #endif
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
