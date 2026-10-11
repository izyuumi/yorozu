import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Yorozu in the share sheet: the shared text or link in an editable note, and at most one picture or file. Send writes
/// it into the App Group (`ShareInbox`); Yorozu sends it the next time it is open, through its outbox.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        let host = UIHostingController(rootView: ShareView(model: model, send: { [weak self] in self?.send(model) }, cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }

    private func send(_ model: ShareModel) {
        do {
            try ShareInbox.write(text: model.text, file: model.file)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            model.problem = String(localized: "Couldn’t keep this for Yorozu. Try again.")
        }
    }
}

@MainActor @Observable final class ShareModel {
    var text = ""
    var file: URL?
    var problem: String?
    var loading = true

    /// Text and a link become the note; the first picture or file is attached.
    func load(_ items: [NSExtensionItem]) async {
        defer { loading = false }
        var lines: [String] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                lines.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let string = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                lines.append(string)
            } else if file == nil, let type = [UTType.image, .item].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                file = await copy(provider, type: type)
            }
        }
        text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The provider's file lives only during its callback: copy it out to the extension's temporary folder.
    private func copy(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return done.resume(returning: nil) }
                let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let target = folder.appending(path: provider.suggestedName.map { $0 + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension) } ?? url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: target)
                    done.resume(returning: target)
                } catch { done.resume(returning: nil) }
            }
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Add a note", text: $model.text, axis: .vertical).lineLimit(3...10)
                    if let file = model.file {
                        Label(file.lastPathComponent, systemImage: "paperclip").lineLimit(1)
                    }
                } footer: {
                    Text("Yorozu sends this the next time it’s open.")
                }
                if let problem = model.problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle("Send to Yorozu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send)
                        .disabled(model.loading || (model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.file == nil))
                }
            }
        }
    }
}
