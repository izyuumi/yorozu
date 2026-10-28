import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// ⌘+ / ⌘− / ⌘0 on the Mac and iPad: one app-wide step per device. The iPad shifts the system's Dynamic Type
// size by the step; the Mac has no Dynamic Type, so its text styles read `textZoom` through `textStyle(_:)`.
// The iPhone follows the system text size only.
enum Zoom {
    static let key = "YorozuZoomStep"
    static let steps = -2...4

    static func clamped(_ step: Int) -> Int { min(max(step, steps.lowerBound), steps.upperBound) }

    #if os(macOS)
    private static let factors: [CGFloat] = [0.75, 0.875, 1, 1.25, 1.5, 1.75, 2]
    static func factor(_ step: Int) -> CGFloat { factors[clamped(step) - steps.lowerBound] }
    #endif
}

extension EnvironmentValues {
    /// The Mac's text zoom; always 1 on iPhone and iPad, where Dynamic Type does the scaling.
    @Entry var textZoom: CGFloat = 1
}

struct ZoomCommands: Commands {
    @AppStorage(Zoom.key) private var step = 0

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(String(localized: "Zoom In")) { step = Zoom.clamped(step + 1) }
                .keyboardShortcut("+")
                .disabled(step >= Zoom.steps.upperBound)
            Button(String(localized: "Zoom Out")) { step = Zoom.clamped(step - 1) }
                .keyboardShortcut("-")
                .disabled(step <= Zoom.steps.lowerBound)
            Button(String(localized: "Actual Size")) { step = 0 }
                .keyboardShortcut("0")
                .disabled(step == 0)
            Divider()
        }
    }
}

extension View {
    /// Applies the stored zoom to a scene's root view.
    func zoomable() -> some View { modifier(Zoomed()) }

    /// Sets `style` at the Mac's zoom only while zoomed, for views that otherwise keep the font the system
    /// gives them: a scene's default text, sidebar rows, `ContentUnavailableView`'s label and description.
    func zoomedFont(_ style: Font.TextStyle = .body) -> some View { modifier(ZoomedDefault(style: style)) }

    /// A text-style font that also follows the Mac's zoom.
    func textStyle(_ style: Font.TextStyle, weight: Font.Weight? = nil, monospaced: Bool = false) -> some View {
        modifier(TextStyleFont(style: style, weight: weight, monospaced: monospaced))
    }
}

extension Font {
    static func zoomed(_ style: TextStyle, _ zoom: CGFloat, weight: Weight? = nil, monospaced: Bool = false) -> Font {
        let design: Design? = monospaced ? .monospaced : nil
        #if os(macOS)
        if zoom != 1 {
            let size = NSFont.preferred(style.appKit, zoom: zoom).pointSize
            return .system(size: size, weight: weight ?? (style == .headline ? .bold : .regular), design: design)
        }
        #endif
        return .system(style, design: design, weight: weight)
    }
}

private struct TextStyleFont: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    let monospaced: Bool
    @Environment(\.textZoom) private var zoom

    func body(content: Content) -> some View {
        content.font(.zoomed(style, zoom, weight: weight, monospaced: monospaced))
    }
}

private struct ZoomedDefault: ViewModifier {
    let style: Font.TextStyle
    @Environment(\.textZoom) private var zoom

    func body(content: Content) -> some View {
        content.font(zoom == 1 ? nil : .zoomed(style, zoom))
    }
}

private struct Zoomed: ViewModifier {
    @AppStorage(Zoom.key) private var step = 0
    @Environment(\.dynamicTypeSize) private var system

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .zoomedFont()
            .environment(\.textZoom, Zoom.factor(step))
            #else
            .dynamicTypeSize(shifted)
            #endif
            // A menu item has one shortcut, so ⌘= (⌘+ without Shift) lives here.
            .background {
                Button(String(localized: "Zoom In")) { step = Zoom.clamped(step + 1) }
                    .keyboardShortcut("=")
                    .disabled(step >= Zoom.steps.upperBound)
                    .hidden()
            }
    }

    #if !os(macOS)
    private var shifted: DynamicTypeSize {
        guard UIDevice.current.userInterfaceIdiom == .pad, let index = DynamicTypeSize.allCases.firstIndex(of: system) else { return system }
        let all = DynamicTypeSize.allCases
        return all[min(max(index + Zoom.clamped(step), all.startIndex), all.endIndex - 1)]
    }
    #endif
}

#if os(macOS)
extension NSFont {
    /// A text-style font at the Mac's zoom, for AppKit text views.
    static func preferred(_ style: TextStyle, zoom: CGFloat) -> NSFont {
        let font = preferredFont(forTextStyle: style)
        return zoom == 1 ? font : font.withSize(font.pointSize * zoom)
    }
}

private extension Font.TextStyle {
    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#else
extension UIFont {
    /// A text-style font at the environment's Dynamic Type size, which carries the iPad's zoom, for UIKit text views.
    static func preferred(_ style: TextStyle, size: DynamicTypeSize) -> UIFont {
        preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)))
    }
}
#endif
