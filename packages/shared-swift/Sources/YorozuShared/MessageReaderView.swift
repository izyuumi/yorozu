import SwiftUI

/// One long message on its own, when the thread is the wrong place to read it: a reply that ran
/// to a page of Markdown is a document, and a document gets a page rather than a bubble.
///
/// Deliberately plain behind the text — no material, no glass. Chrome can be translucent;
/// something you are going to read for a minute should not be.
public struct MessageReaderView: View {
    public let text: String
    /// What the title says it is — "Reply" or "Message" — since the reader loses the side of
    /// the thread the bubble was on.
    public let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    public init(text: String, title: String = "Message") {
        self.text = text
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownText(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyToPasteboard(text)
                        withAnimation { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(copied ? "Copied" : "Copy message")
                    // Confirms, then offers the copy again, exactly as the code blocks do.
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { copied = false }
                    }
                }
            }
        }
    }
}
