import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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

/// The composer's paperclip: paste an image, pick media from the library, or choose one file.
/// Both platforms offer every route, so this lives beside the rest of the composer rather than
/// in the iOS app.
///
/// Whatever is picked is read into memory whole, because that is what the wire carries — so the
/// 5 MB cap is checked here, in front of the person who chose the file, rather than at the
/// other end where there is nobody to tell.
struct AttachButton: View {
    let onPick: ([MessageAttachment]) -> Void
    let onTooLarge: () -> Void

    @State private var photos: [PhotosPickerItem] = []
    @State private var browsingFiles = false

    var body: some View {
        Menu {
            // A picker inside the menu, so choosing "Photos" opens it directly instead of
            // dismissing the menu and waiting for a second tap.
            PhotosPicker(selection: $photos, maxSelectionCount: MessageAttachment.maxCount, matching: .any(of: [.images, .videos])) {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            PasteButton(payloadType: PastedImage.self) { images in
                guard let image = images.first else { return }
                stagePastedImage(image, onPick: { onPick([$0]) }, onTooLarge: onTooLarge)
            }
            .keyboardShortcut("v", modifiers: .command)
            Button("Files", systemImage: "folder") { browsingFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: controlTarget, height: controlTarget)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Attach or paste a photo or file")
        .task(id: photos) { await loadPhotos() }
        .fileImporter(
            isPresented: $browsingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            let picked = urls.prefix(MessageAttachment.maxCount).compactMap(loadFile)
            if !picked.isEmpty { onPick(picked) }
        }
    }

    private func loadPhotos() async {
        let selected = photos
        guard !selected.isEmpty else { return }
        defer { photos = [] }
        var picked: [MessageAttachment] = []
        for photo in selected {
            guard let data = try? await photo.loadTransferable(type: Data.self) else { continue }
            let type = photo.supportedContentTypes.first ?? .image
            let name = "photo.\(type.preferredFilenameExtension ?? "jpg")"
            if let attachment = makeAttachment(name: name, mime: type.preferredMIMEType ?? "image/jpeg", bytes: data) {
                picked.append(attachment)
            }
        }
        if !picked.isEmpty { onPick(picked) }
    }

    private func loadFile(_ url: URL) -> MessageAttachment? {
        // A document picked outside the app's container is only readable inside this pair.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        return makeAttachment(
            name: url.lastPathComponent,
            mime: type?.preferredMIMEType ?? "application/octet-stream",
            bytes: data
        )
    }

    private func makeAttachment(name: String, mime: String, bytes: Data) -> MessageAttachment? {
        guard let attachment = MessageAttachment(name: name, mime: mime, bytes: bytes) else {
            onTooLarge()
            return nil
        }
        return attachment
    }
}

/// The staged file above the composer, with the way to change your mind about it.
struct StagedAttachment: View {
    let attachment: MessageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if attachment.isImage, let bytes = attachment.bytes, let image = Image.from(data: bytes) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                Text(attachment.size).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Remove", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
