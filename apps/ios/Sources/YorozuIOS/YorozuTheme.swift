import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

extension ToolbarItemPlacement {
    static var pinnedAction: ToolbarItemPlacement {
        #if os(iOS)
        if #available(iOS 27, *) { return .topBarPinnedTrailing }
        #endif
        return .primaryAction
    }
}

extension EnvironmentValues {
    @Entry var accent = Accent.vermilion
}

extension View {
    func readableRow(gutter: CGFloat = LayoutMetrics.gutter) -> some View {
        padding(.horizontal, gutter)
            .frame(maxWidth: LayoutMetrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder func yorozuGlass(in shape: some Shape) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder func yorozuBottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26, macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { content().background(.bar) }
        }
    }

    @ViewBuilder func navigationBarStaysVisible() -> some View {
        #if os(iOS)
        if #available(iOS 27, *) {
            toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder func navigationSubtitleIfAvailable(_ text: String) -> some View {
        if #available(iOS 26, macOS 26, *) {
            navigationSubtitle(text)
        } else {
            self
        }
    }

    func yorozuTint() -> some View { modifier(YorozuTint()) }

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
        content.onChange(of: appearance, initial: true) { _, appearance in
            NSApp.appearance = switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
        #else
        content.onChange(of: appearance, initial: true) { _, appearance in
            let style: UIUserInterfaceStyle = switch appearance {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { window.overrideUserInterfaceStyle = style }
            }
        }
        #endif
    }
}

extension AnyTransition {
    /// Slides down from the top edge, or only fades with Reduce Motion on.
    static func fromTop(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    static func controlSwap(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity)
    }
}

extension View {
    func composerControl() -> some View {
        frame(width: LayoutMetrics.controlCircle, height: LayoutMetrics.controlCircle)
            .background(.fill.tertiary, in: Circle())
            .frame(width: max(LayoutMetrics.controlCircle, controlTarget), height: max(LayoutMetrics.controlCircle, controlTarget))
            .contentShape(.rect)
    }
}
