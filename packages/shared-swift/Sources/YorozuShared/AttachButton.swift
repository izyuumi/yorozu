import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
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
    onTooLarge: () -> Void
) {
    guard image.bytes.count <= MessageAttachment.maxBytes else { return onTooLarge() }
    guard let attachment = pastedImageAttachment(bytes: image.bytes) else { return }
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

    @State private var photos: [PhotosPickerItem] = []
    @State private var browsingFiles = false
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
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: controlTarget, height: controlTarget)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Attach photos or files")
        .task(id: photos) { await loadPhotos() }
        .fileImporter(
            isPresented: $browsingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            loadFiles(urls)
        }
        #if os(iOS)
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { data in
                    // The camera hands over a picture, not a file: the name is made here, the
                    // same way the library's is.
                    stage([(name: "photo.jpg", mime: "image/jpeg", bytes: data)])
                }
                .ignoresSafeArea()
            }
        #endif
    }

    private func loadPhotos() async {
        guard !photos.isEmpty else { return }
        let picked = photos
        // Cleared whatever happens, so picking the same photo again is a new pick rather than
        // a selection that is already "current" and never fires.
        defer { photos = [] }
        var picks: [(name: String, mime: String, bytes: Data)] = []
        for item in picked {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // A PhotosPickerItem carries a type but not always a name, so one is made from the
            // type: what the user sees, and what a text-only model is told was attached.
            let type = item.supportedContentTypes.first ?? .image
            picks.append((
                name: "photo.\(type.preferredFilenameExtension ?? "jpg")",
                mime: type.preferredMIMEType ?? "image/jpeg",
                bytes: data
            ))
        }
        stage(picks)
    }

    private func loadFiles(_ urls: [URL]) {
        var picks: [(name: String, mime: String, bytes: Data)] = []
        for url in urls {
            // A document picked outside the app's container is only readable inside this pair.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            picks.append((
                name: url.lastPathComponent,
                mime: type?.preferredMIMEType ?? "application/octet-stream",
                bytes: data
            ))
        }
        stage(picks)
    }

    #if os(iOS)
        private func pasteImage() {
            guard let image = UIPasteboard.general.images?.first,
                let data = image.jpegData(compressionQuality: 1)
            else { return }
            stage([(name: "pasted.jpg", mime: "image/jpeg", bytes: data)])
        }
    #endif

    /// The one funnel every way in goes through: reduce, cap, hand over what survived, and say
    /// so once if anything did not. One alert for a batch rather than one per file.
    private func stage(_ picks: [(name: String, mime: String, bytes: Data)]) {
        guard !picks.isEmpty else { return }
        var staged: [MessageAttachment] = []
        var refused = picks.count > remaining
        for pick in picks.prefix(max(0, remaining)) {
            if let attachment = attachmentForSending(name: pick.name, mime: pick.mime, bytes: pick.bytes) {
                staged.append(attachment)
            } else {
                refused = true
            }
        }
        if !staged.isEmpty { onPick(staged) }
        if refused { onTooLarge() }
    }
}

#if os(iOS)
    /// The system camera, which has no SwiftUI form of its own: `UIImagePickerController` is
    /// still the only way to take one picture without standing up a capture session by hand.
    private struct CameraPicker: UIViewControllerRepresentable {
        let onCapture: (Data) -> Void
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
                    : "Attached file, \(attachment.name)"
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
            }
            .frame(width: Self.side, height: Self.side)
            .background(.quaternary)
        }
    }
}
