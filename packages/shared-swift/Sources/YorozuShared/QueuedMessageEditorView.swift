import SwiftUI

struct QueuedMessageEditorRoute: Identifiable {
    let id: String
    let message: MessageData
}

/// Edits the existing encrypted queue entry, leaving the main composer and attachments intact.
struct QueuedMessageEditorView: View {
    let model: ChatModel
    let route: QueuedMessageEditorRoute
    @State private var text: String
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss

    init(model: ChatModel, route: QueuedMessageEditorRoute) {
        self.model = model; self.route = route
        _text = State(initialValue: route.message.text)
    }

    var body: some View {
        Form {
            Section("Message") {
                TextField("Message", text: $text, axis: .vertical)
                    .accessibilityIdentifier("queued-message-text")
            }
            if !route.message.attachments.isEmpty {
                Section("Attachments") {
                    ForEach(Array(route.message.attachments.enumerated()), id: \.offset) { _, file in
                        Label(file.name, systemImage: "paperclip")
                    }
                }
            }
            Section {
                Text("Your message stays saved while waiting for your Mac. After 30 minutes, confirm Still send before delivery.")
                    .font(.footnote).foregroundStyle(.secondary)
                if saveFailed {
                    Text("The edit could not be saved. Your queued message is unchanged.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Edit queued message")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.endQueuedMessageEdit(route.id); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if model.editQueuedMessage(route.id, text: text) { dismiss() }
                    else { saveFailed = true }
                }
                .disabled(!model.canEditQueuedMessage(route.id) ||
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && route.message.attachments.isEmpty)
                .accessibilityIdentifier("queued-message-save")
            }
        }
    }
}
