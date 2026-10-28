import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YorozuWire

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        let done: () -> Void = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareView(model: model,
            send: { model.send(done: done) },
            later: { model.later(done: done) },
            cancel: { [weak self] in
                model.stop()
                self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
}

@MainActor @Observable final class ShareModel {
    var text = ""
    var file: URL?
    var problem: String?
    var loading = true
    var convId: String?
    var sending = false
    var progress: Double?
    var failure: String?
    let directory = ShareInbox.published()
    private let messageId = WireEvent.newId()
    private let attachmentId = WireEvent.newId()
    private var task: Task<Void, Never>?

    /// Sends from here when this device is paired, else hands the share to the app as before.
    func send(done: @escaping () -> Void) {
        guard let pairing = try? Pairing.load(), pairing.paired else { return later(done: done) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = file.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return ShareSender.File(url: url, attachment: Attachment(id: attachmentId, name: Attachment.wireName(url.lastPathComponent),
                mime: Attachment.wireMime(mime), size: size))
        }
        let message = Message(convId: convId ?? messageId, messageId: messageId, text: text,
            attachments: file.map { [$0.attachment] })
        failure = nil
        progress = file == nil ? nil : 0
        sending = true
        task = Task {
            do {
                try await ShareSender.send(message, file: file, pairing: pairing) { self.progress = $0 }
                ShareInbox.announceSent()
                done()
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }

    func later(done: () -> Void) {
        stop()
        do {
            try ShareInbox.write(text: text, file: file, convId: convId, messageId: messageId)
            done()
        } catch {
            failure = String(localized: "Couldn’t keep this for Yorozu. Try again.")
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

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
        if let file, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > directory.maxBytes {
            let format = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary) }
            problem = String(localized: "“\(file.lastPathComponent)” is \(format(size)). Yorozu sends files up to \(format(directory.maxBytes)).")
            self.file = nil
        }
    }

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
    let later: () -> Void
    let cancel: () -> Void
    @ScaledMetric private var previewSide: CGFloat = 160

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Add a note", text: $model.text, axis: .vertical).lineLimit(3...10)
                    if let file = model.file {
                        VStack {
                            FileThumbnail(url: file, side: previewSide)
                            Label(file.lastPathComponent, systemImage: "paperclip").lineLimit(1).truncationMode(.middle)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .disabled(model.sending)
                Section {
                    Picker(String(localized: "Conversation"), selection: $model.convId) {
                        Text("New Conversation").tag(String?.none)
                        ForEach(model.directory.conversations) { conversation in
                            Text(conversation.title.isEmpty ? String(localized: "Untitled") : conversation.title)
                                .lineLimit(1)
                                .tag(String?.some(conversation.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                .disabled(model.sending)
                if let problem = model.problem { Text(problem).foregroundStyle(.red) }
                if model.sending {
                    Section {
                        if let progress = model.progress { ProgressView("Sending…", value: progress) } else { ProgressView("Sending…") }
                    }
                } else if let failure = model.failure {
                    Section {
                        Text(failure).foregroundStyle(.red)
                        Button("Try Again", action: send)
                        Button("Send Later", action: later)
                    }
                }
            }
            .navigationTitle("Send to Yorozu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send)
                        .disabled(model.loading || model.sending || (model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.file == nil))
                }
            }
        }
    }
}
