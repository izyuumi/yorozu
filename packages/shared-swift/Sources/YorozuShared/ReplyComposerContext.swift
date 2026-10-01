import SwiftUI

/// Quoted context shares the composer's available width. Text follows Dynamic Type;
/// the dismiss glyph belongs to its own control and keeps the existing accessible hit area.
struct ReplyComposerContext: View {
    let target: ReplyTarget
    let onCancel: () -> Void
    private static let dismissGlyph: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: LayoutMetrics.inner) {
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                Text(target.role == .user ? String(localized: "Replying to you") : String(localized: "Replying to Yorozu"))
                    .font(.scaled(.caption).weight(.semibold))
                    .lineLimit(2)
                Text(target.preview).font(.scaled(.caption)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: Self.dismissGlyph, weight: .medium))
                    .frame(minWidth: controlTarget, minHeight: controlTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
            .accessibilityHint("Keeps your text and attachments")
        }
        .foregroundStyle(.secondary)
    }
}
