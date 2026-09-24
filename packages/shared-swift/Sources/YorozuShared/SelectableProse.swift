#if os(iOS)
    import SwiftUI
    import UIKit

    /// What a bubble's prose looks like when it is a `UITextView` rather than a `Text`: the
    /// typeface design and colours the bubble set with SwiftUI modifiers, which a UIKit view
    /// cannot read back out of the environment.
    struct ProseStyle {
        var serif: Bool
        var ink: UIColor
        var tint: UIColor

        /// The same relative sizes ``MarkdownText`` gives headings, so both paths track
        /// Dynamic Type alike. Bold, italic and code become font traits here.
        func font(heading level: Int?, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
            let (style, weight): (UIFont.TextStyle, UIFont.Weight) = switch level {
            case 1: (.title2, .bold)
            case 2: (.title3, .semibold)
            case 3: (.headline, .semibold)
            case .some: (.subheadline, .semibold)
            case nil: (.body, .regular)
            }
            let design: UIFontDescriptor.SystemDesign = traits.contains(.traitMonoSpace) ? .monospaced : serif ? .serif : .default
            var descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
            descriptor = descriptor.withDesign(design) ?? descriptor
            descriptor = descriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            descriptor = descriptor.withSymbolicTraits(traits.subtracting(.traitMonoSpace)) ?? descriptor
            return UIFont(descriptor: descriptor, size: 0)
        }
    }

    extension EnvironmentValues {
        /// Set by a message bubble. Nil everywhere prose stays a SwiftUI `Text`.
        @Entry var proseStyle: ProseStyle?
    }

    /// A read-only, non-scrolling `UITextView` sized to its text: the one control on iOS whose
    /// long press selects by word and letter. SwiftUI's `Text` selects itself whole.
    struct SelectableProse: UIViewRepresentable {
        let text: AttributedString
        /// Heading level, or nil for body prose.
        let level: Int?
        let style: ProseStyle

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.isEditable = false
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.adjustsFontForContentSizeCategory = true
            view.accessibilityTraits = level == nil ? .staticText : .header
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            view.attributedText = styled
            view.tintColor = style.tint
            view.linkTextAttributes = [.foregroundColor: style.tint, .underlineStyle: NSUnderlineStyle.single.rawValue]
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
            let fitted = uiView.sizeThatFits(CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            // The proposed width, not the text's: a short line still owns its whole row.
            return CGSize(width: proposal.width ?? fitted.width, height: fitted.height)
        }

        /// Foundation's inline intents are what SwiftUI draws bold, italic and code from, and
        /// UIKit draws none of them; nor do SwiftUI-scoped colours (the search highlight, the
        /// code background) survive `NSAttributedString.init`. Both are re-applied here.
        private var styled: NSAttributedString {
            let result = NSMutableAttributedString(text)
            result.addAttributes(
                [.font: style.font(heading: level), .foregroundColor: style.ink],
                range: NSRange(location: 0, length: result.length)
            )
            for run in text.runs {
                let range = NSRange(run.range, in: text)
                let intent = run.inlinePresentationIntent ?? []
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if intent.contains(.code) { traits.insert(.traitMonoSpace) }
                if !traits.isEmpty {
                    result.addAttribute(.font, value: style.font(heading: level, traits: traits), range: range)
                }
                if intent.contains(.strikethrough) {
                    result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
                if let background = run.swiftUI.backgroundColor {
                    result.addAttribute(.backgroundColor, value: UIColor(background), range: range)
                }
            }
            return result
        }
    }
#endif
