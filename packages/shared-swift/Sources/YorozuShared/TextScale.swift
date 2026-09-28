import Observation
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// How large the Mac draws text, stepped by ⌘+ and ⌘− and reset by ⌘0, and remembered.
///
/// macOS ignores `dynamicTypeSize`, so text styles cannot be scaled through the environment;
/// every text style resolves through ``SwiftUI/Font/scaled(_:)`` instead, and because this is
/// observable, a body that read it redraws when it changes. The phone already has Dynamic Type
/// and keeps this at 1.
@Observable
public final class TextScale: @unchecked Sendable {
    // Unchecked: `value` is only written on the main actor, by the menu commands below.
    public static let shared = TextScale()
    public static let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    static let key = "textScale"

    public private(set) var value: Double

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.key)
        value = Self.steps.contains(stored) ? stored : 1
    }

    public var canGrow: Bool { value < Self.steps[Self.steps.count - 1] }
    public var canShrink: Bool { value > Self.steps[0] }

    @MainActor public func grow() { set(Self.steps.first { $0 > value }) }
    @MainActor public func shrink() { set(Self.steps.last { $0 < value }) }
    @MainActor public func reset() { set(1) }

    @MainActor private func set(_ step: Double?) {
        guard let step else { return }
        value = step
        UserDefaults.standard.set(step, forKey: Self.key)
    }
}

extension Font {
    /// A text style at the reader's ``TextScale``. At 1 it is exactly the system style.
    public static func scaled(_ style: TextStyle) -> Font {
        #if os(macOS)
            let scale = TextScale.shared.value
            guard scale != 1 else { return .system(style) }
            let font = NSFont.preferredFont(forTextStyle: style.appKit)
            return Font(font.withSize((font.pointSize * scale).rounded()))
        #else
            .system(style)
        #endif
    }
}

#if os(macOS)
    extension Font.TextStyle {
        fileprivate var appKit: NSFont.TextStyle {
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
#endif
