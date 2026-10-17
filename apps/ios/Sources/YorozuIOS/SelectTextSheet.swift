import SwiftUI

/// "Select Text" from a message's context menu: the whole message in a sheet, where any part of it can be selected and
/// copied. A bubble's own text selection on iOS takes the whole text only.
struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .padding(.horizontal, LayoutMetrics.gutter)
                .navigationTitle(String(localized: "Select Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
                }
        }
    }
}

#if os(macOS)
/// SwiftUI's selection already picks a range on the Mac.
private struct SelectableText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, LayoutMetrics.stack)
        }
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
    }
}
#else
/// A read-only `UITextView`: handles, the loupe and the edit menu for any range.
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = [.link]
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#endif
