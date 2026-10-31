import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The accent and palette, shared by the app and the widgets.
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

enum YorozuPalette {
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
