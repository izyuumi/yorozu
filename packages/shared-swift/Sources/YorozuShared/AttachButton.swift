import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

struct PastedImage: Transferable {
    let bytes: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { PastedImage(bytes: $0) }
    }
}

func pastedImageAttachment(bytes: Data) -> MessageAttachment? {
    guard
        let source = CGImageSourceCreateWithData(bytes as CFData, nil),
        let identifier = CGImageSourceGetType(source) as String?,
        let type = UTType(identifier), type.conforms(to: .image)
    else { return nil }
    return MessageAttachment(
        name: "pasted-image.\(type.preferredFilenameExtension ?? "png")",
        mime: type.preferredMIMEType ?? "image/png",
        bytes: bytes
    )
}

func stagePastedImage(
    _ image: PastedImage,
    onPick: (MessageAttachment) -> Void,
    onTooLarge: () -> Void,
    onFailure: ((String) -> Void)? = nil
) {
    guard image.bytes.count <= MessageAttachment.maxBytes else {
        if let onFailure { onFailure(String(localized: "Each attachment must be 5 MB or smaller.")) }
        else { onTooLarge() }
        return
    }
    guard let attachment = pastedImageAttachment(bytes: image.bytes) else {
        onFailure?(String(localized: "Couldn’t read the image. Copy it again or choose another file."))
        return
    }
    onPick(attachment)
}

/// The composer's paperclip: several photos from the library, a picture taken there and then on
/// a phone, or files from the document picker — up to what this message may still carry.
///
/// Whatever is picked is read into memory whole, because that is what the wire carries. A photo
/// is reduced before the cap is applied — see ``attachmentForSending`` — so a picture taken
/// today fits instead of being refused for a size it no longer has. Anything still over the cap
/// is refused here, in front of the person who chose it, rather than at the other end where
/// there is nobody to tell.
struct AttachButton: View {
    /// How many more attachments this message may take. The pickers select up to it, and the
    /// composer disables the whole button at zero.
    let remaining: Int
    let onPick: ([MessageAttachment]) -> Void
    let onTooLarge: () -> Void
    var onLoadingChanged: (Bool) -> Void = { _ in }

    @State private var photos: [PhotosPickerItem] = []
    @State private var browsingFiles = false
    @State private var isLoading = false
    @State private var activeLoadID: UUID?
    @State private var failureMessage: String?
    @State private var retrySources: [AttachmentSource] = []
    @State private var loadingTask: Task<Void, Never>?
    #if os(iOS)
        @State private var takingPhoto = false
    #endif

    var body: some View {
        Menu {
            // A picker inside the menu, so choosing "Photos" opens it directly instead of
            // dismissing the menu and waiting for a second tap.
            PhotosPicker(
                selection: $photos,
                maxSelectionCount: max(1, remaining),
                matching: .images
            ) {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            #if os(iOS)
                // Offered only where there is a camera to open: a simulator has none, and a menu
                // item that cannot work is worse than one that is not there.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo", systemImage: "camera") { takingPhoto = true }
                }
            #endif
            Button("Files", systemImage: "folder") { browsingFiles = true }
            #if os(iOS)
                // The phone's way to the paste the Mac gets from ⌘V. `hasImages` is only a
                // question about the pasteboard and does not read it, so it raises no banner;
                // the read itself happens on the tap, which is somebody asking for it.
                if UIPasteboard.general.hasImages {
                    Button("Paste", systemImage: "doc.on.clipboard") { pasteImage() }
                }
            #endif
        } label: {
            Group {
                if isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: "plus").font(.body.weight(.semibold)) }
            }
                .foregroundStyle(.secondary)
                .frame(width: controlTarget, height: controlTarget)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(isLoading ? "Loading attachments" : "Attach photos or files")
        .disabled(isLoading || remaining <= 0)
        .help(remaining <= 0 ? "Remove an attachment to add another" : "Attach photos or files")
        .accessibilityHint(remaining <= 0 ? "Remove an attachment to add another" : "Choose photos or files for this message")
        .alert("Attachments couldn’t be added", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            if !retrySources.isEmpty {
                Button("Retry failed attachments") {
                    let sources = retrySources
                    loadingTask = Task { await load(sources) }
                }
            }
            Button("OK", role: .cancel) { retrySources = [] }
        } message: {
            Text(failureMessage ?? "")
        }
        .onDisappear {
            activeLoadID = nil
            loadingTask?.cancel()
            isLoading = false
            onLoadingChanged(false)
        }
        .task(id: photos) { await loadPhotos() }
        .fileImporter(
            isPresented: $browsingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): loadFiles(urls)
            case .failure(let error):
                guard (error as NSError).code != NSUserCancelledError else { return }
                retrySources = []
                reportFailure(String(localized: "Couldn’t open the selected files. Choose them again and check that they’re available on this device."))
            }
        }
        #if os(iOS)
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { data in
                    // The camera hands over a picture, not a file: the name is made here, the
                    // same way the library's is.
                    stage([(name: "photo.jpg", mime: "image/jpeg", bytes: data)])
                } onFailure: {
                    reportFailure(String(localized: "Couldn’t read the photo. Try taking it again."))
                }
                .ignoresSafeArea()
            }
        #endif
    }

    private func loadPhotos() async {
        guard !photos.isEmpty else { return }
        let picked = photos
        defer { if photos == picked { photos = [] } }
        let sources = picked.enumerated().map { index, item in
            let type = item.supportedContentTypes.first ?? .image
            return AttachmentSource(
                name: "photo-\(index + 1).\(type.preferredFilenameExtension ?? "jpg")",
                mime: type.preferredMIMEType ?? "image/jpeg",
                load: { try await item.loadTransferable(type: Data.self) }
            )
        }
        await load(sources)
    }

    private func loadFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let sources = urls.map { url in
            AttachmentSource(
                name: url.lastPathComponent,
                mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                load: {
                    // Reading cloud-backed documents may block. Keep that work off the UI
                    // thread and retain security-scoped access for exactly the read's lifetime.
                    try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url)
                    }.value
                }
            )
        }
        loadingTask = Task { await load(sources) }
    }

    private func load(_ sources: [AttachmentSource]) async {
        guard !Task.isCancelled else { return }
        let loadID = UUID()
        activeLoadID = loadID
        isLoading = true
        onLoadingChanged(true)
        failureMessage = nil
        retrySources = []
        defer {
            if activeLoadID == loadID {
                activeLoadID = nil
                isLoading = false
                onLoadingChanged(false)
            }
        }
        do {
            let result = try await AttachmentAcquisition.load(sources)
            try Task.checkCancellation()
            guard activeLoadID == loadID else { return }
            retrySources = result.failed
            if !result.picks.isEmpty { stage(result.picks) }
            if !result.failed.isEmpty {
                let names = result.failed.map(\.name).joined(separator: ", ")
                reportFailure(String(localized: "Couldn’t load: \(names). Try again, or choose another file."))
            }
        } catch is CancellationError {
            // Leaving the conversation cancels acquisition; never attach later to another draft.
        } catch {
            reportFailure(String(localized: "Couldn’t load the attachments. Choose them again."))
        }
    }

    private func reportFailure(_ message: String) {
        failureMessage = failureMessage.map { $0 + "\n\n" + message } ?? message
    }

    #if os(iOS)
        private func pasteImage() {
            stage(pasteboardImagePicks())
        }
    #endif

    private func stage(_ picks: [(name: String, mime: String, bytes: Data)]) {
        // Camera and menu Paste start here; async acquisition already began its attempt.
        // Clear old feedback before callbacks can add errors from this same batch.
        let freshAttempt = !isLoading
        if freshAttempt {
            failureMessage = nil
            retrySources = []
            onLoadingChanged(true)
        }
        defer { if freshAttempt { onLoadingChanged(false) } }
        stageAttachments(picks, remaining: remaining, onPick: onPick, onTooLarge: onTooLarge, onFailure: reportFailure)
    }
}

/// The one funnel every way in goes through: reduce, cap, hand over what survived, and say
/// so once if anything did not. One alert for a batch rather than one per file.
func stageAttachments(
    _ picks: [(name: String, mime: String, bytes: Data)],
    remaining: Int,
    onPick: ([MessageAttachment]) -> Void,
    onTooLarge: () -> Void,
    onFailure: ((String) -> Void)? = nil
) {
    guard !picks.isEmpty else {
        onFailure?(String(localized: "Couldn’t read the image. Copy it again or choose another file."))
        return
    }
    var staged: [MessageAttachment] = []
    var unreadable: [String] = []
    var oversized: [String] = []
    var overCount = false
    for pick in picks {
        guard staged.count < max(0, remaining) else { overCount = true; continue }
        if pick.mime.hasPrefix("image/") {
            guard let source = CGImageSourceCreateWithData(pick.bytes as CFData, nil),
                CGImageSourceGetCount(source) > 0 else {
                unreadable.append(pick.name)
                continue
            }
        }
        if let attachment = attachmentForSending(name: pick.name, mime: pick.mime, bytes: pick.bytes) {
            staged.append(attachment)
        } else {
            oversized.append(pick.name)
        }
    }
    if !staged.isEmpty { onPick(staged) }
    if let onFailure {
        var messages: [String] = []
        if !unreadable.isEmpty {
            let names = unreadable.joined(separator: ", ")
            messages.append(String(localized: "Couldn’t read: \(names). Choose another file."))
        }
        if !oversized.isEmpty {
            let names = oversized.joined(separator: ", ")
            messages.append(String(localized: "Too large: \(names). Each attachment must be 5 MB or smaller."))
        }
        if overCount { messages.append(String(localized: "A message can contain up to 10 attachments. Remove one to add another.")) }
        if !messages.isEmpty { onFailure(messages.joined(separator: "\n\n")) }
    } else if !oversized.isEmpty || overCount {
        onTooLarge()
    }
}

/// Every image on the pasteboard, ready for ``stageAttachments`` — what the + menu's Paste and
/// the message field's own Paste (⌘V, or the edit menu) both read.
#if os(iOS)
    func pasteboardHasImages() -> Bool { UIPasteboard.general.hasImages }

    func pasteboardImagePicks() -> [(name: String, mime: String, bytes: Data)] {
        (UIPasteboard.general.images ?? []).enumerated().map { index, image in
            // An empty conversion stays in the batch so staging can name the failed image
            // instead of silently dropping it beside successfully converted ones.
            (name: "pasted-\(index + 1).jpg", mime: "image/jpeg",
             bytes: image.jpegData(compressionQuality: 1) ?? Data())
        }
    }
#else
    func pasteboardHasImages() -> Bool {
        let board = NSPasteboard.general
        // Rich text from Pages, Word or a web page often carries a picture of itself beside the
        // text: that is a text paste. A file copied in Finder has its name as text, and is not.
        if board.availableType(from: [.string]) != nil, board.availableType(from: [.fileURL]) == nil {
            return false
        }
        return board.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    func pasteboardImagePicks() -> [(name: String, mime: String, bytes: Data)] {
        let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
        return images.enumerated().map { index, image in
            let bytes = image.tiffRepresentation
                .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            return (name: "pasted-\(index + 1).png", mime: "image/png", bytes: bytes ?? Data())
        }
    }
#endif

#if os(iOS)
    /// The system camera, which has no SwiftUI form of its own: `UIImagePickerController` is
    /// still the only way to take one picture without standing up a capture session by hand.
    private struct CameraPicker: UIViewControllerRepresentable {
        let onCapture: (Data) -> Void
        let onFailure: () -> Void
        @Environment(\.dismiss) private var dismiss

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            private let parent: CameraPicker

            init(_ parent: CameraPicker) { self.parent = parent }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                // Full quality here, because ``attachmentForSending`` is what reduces it: the
                // resize and the cap are decided in one place for every way a picture gets in.
                if let image = info[.originalImage] as? UIImage,
                    let data = image.jpegData(compressionQuality: 1)
                {
                    parent.onCapture(data)
                } else {
                    parent.onFailure()
                }
                parent.dismiss()
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                parent.dismiss()
            }
        }
    }
#endif

/// What is staged above the composer: a horizontal run of thumbnails, each with the way to
/// change your mind about it, which is how Signal shows the same thing. A strip rather than a
/// list, because several pictures side by side is the case this is for.
struct StagedStrip: View {
    let attachments: [MessageAttachment]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                // By offset: two pictures picked from the same album really can be equal, and
                // removing one of them must not take the other.
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    StagedThumbnail(attachment: attachment) { onRemove(index) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }
}

/// One staged file: the picture itself where there is one, the name where there is not, and the
/// way to take it back off.
private struct StagedThumbnail: View {
    let attachment: MessageAttachment
    let onRemove: () -> Void

    private static let side: CGFloat = 56

    var body: some View {
        thumbnail
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.body)
                        .padding(2)
                        // Hit area wider than the glyph; hangs past the thumbnail's corner.
                        .frame(width: controlTarget, height: controlTarget, alignment: .topTrailing)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.name)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                attachment.isImage
                    ? "Attached image, \(attachment.name)"
                    : "Attached file, \(attachment.name), \(attachment.size)"
            )
    }

    @ViewBuilder private var thumbnail: some View {
        if attachment.isImage, let bytes = attachment.bytes, let image = Image.from(data: bytes) {
            image.resizable().scaledToFill()
        } else {
            VStack(spacing: 2) {
                Image(systemName: "doc").font(.title3).foregroundStyle(.secondary)
                Text(attachment.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                Text(attachment.size)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.side, height: Self.side)
            .background(.quaternary)
        }
    }
}
