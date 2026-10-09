import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// v1 packages/shared-swift AttachButton.swift, ImageDownscale.swift and AttachmentAcquisition.swift,
// for files of any type up to 50 MB: picked files are copied to disk at once and never read into memory whole.

/// One file staged in the composer, in its own folder under `tmp/Drafts/`.
struct DraftFile: Identifiable, Equatable, Sendable {
    struct Variant: Equatable, Sendable {
        var url: URL
        var name: String
        var mime: String
        var bytes: Int
        var sha256: String

        var size: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    }

    let id: UUID
    /// What is sent by default: an image reduced to ``imageMaxPixels`` when it needed it, anything else as picked.
    var file: Variant
    /// The image as picked, when `file` is a reduced copy and the original is within the limit: "Send original".
    var original: Variant?
    var sendOriginal = false
    let folder: URL

    var chosen: Variant { sendOriginal ? original ?? file : file }
    var isImage: Bool { file.mime.hasPrefix("image/") }

    func discard() { try? FileManager.default.removeItem(at: folder) }

    static let drafts = FileManager.default.temporaryDirectory.appending(path: "Drafts", directoryHint: .isDirectory)

    /// Drafts do not outlive the app.
    static func clearAll() { try? FileManager.default.removeItem(at: drafts) }

    enum Refusal: Error {
        case unreadable, tooLarge
    }

    /// The long edge a staged image is reduced to (#316): more than any vision model reads an image at.
    static let imageMaxPixels = 2048
    /// Where a re-encode stops being visible.
    static let jpegQuality: CGFloat = 0.85
    /// Image types sent as they are when small enough. HEIC and TIFF are re-encoded whatever their size:
    /// a model on the other end may not read HEIC, and an uncompressed TIFF is megabytes of picture.
    private static let sendableImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Moves a picked file (a temporary copy) into its own draft folder, reduces an image, and hashes what may
    /// be sent. Blocking: call off the main actor.
    static func stage(_ source: URL, name: String) throws -> DraftFile {
        let id = UUID()
        let folder = drafts.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let name = safeFileName(name)
            let target = folder.appending(path: name)
            try FileManager.default.moveItem(at: source, to: target)
            let type = UTType(filenameExtension: target.pathExtension)
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            let bytes = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            var original = Variant(url: target, name: name, mime: mime, bytes: bytes, sha256: "")
            if type?.conforms(to: .image) == true {
                guard let image = CGImageSourceCreateWithURL(target as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
                    throw Refusal.unreadable
                }
                let reducedURL = folder.appending(path: ".reduced.jpg")
                if reduce(image, mime: mime, to: reducedURL) {
                    let reducedBytes = try reducedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard reducedBytes <= AttachmentLimits.maxBytes else { throw Refusal.tooLarge }
                    // The name follows the bytes: a `.heic` that is now a JPEG says so.
                    let reduced = Variant(url: reducedURL, name: "\((name as NSString).deletingPathExtension).jpg", mime: "image/jpeg",
                                          bytes: reducedBytes, sha256: try sha256Hex(of: reducedURL))
                    if bytes <= AttachmentLimits.maxBytes { original.sha256 = try sha256Hex(of: target) }
                    return DraftFile(id: id, file: reduced, original: bytes <= AttachmentLimits.maxBytes ? original : nil, folder: folder)
                }
            }
            guard bytes <= AttachmentLimits.maxBytes else { throw Refusal.tooLarge }
            original.sha256 = try sha256Hex(of: target)
            return DraftFile(id: id, file: original, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Writes a JPEG at most ``imageMaxPixels`` on its long edge, upright, when the image is longer than
    /// that or of a type not sent as it is. ImageIO decodes, resizes and applies the EXIF orientation in
    /// one step, without the full-size bitmap.
    private static func reduce(_ source: CGImageSource, mime: String, to url: URL) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        let longEdge = max(width, height)
        guard !sendableImageTypes.contains(mime) || longEdge > imageMaxPixels else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, imageMaxPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// The draft as a `.txt` file: "Send as Text File" for a draft over the message limit.
    static func textFile(_ text: String) throws -> DraftFile {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(text.utf8).write(to: source)
        return try stage(source, name: String(localized: "attachment.textFileName", defaultValue: "Message.txt"))
    }
}

/// A photo or video from the library, copied out of the picker's temporary file.
private struct PickedMedia: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { try PickedMedia(copying: $0.file) }
        FileRepresentation(importedContentType: .movie) { try PickedMedia(copying: $0.file) }
    }

    init(copying file: URL) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: url)
        self.url = url
        name = file.lastPathComponent
    }
}

/// Where one picked file comes from: loaded to a file on disk, which staging moves on.
private struct AttachmentSource {
    let name: String
    /// A temporary copy of the file, which staging moves on, and its own name when it has a better one.
    let load: () async throws -> (url: URL, name: String?)?
}

/// The composer's +: photos and videos from the library, a photo taken there and then, files from
/// the document picker, and pasted images, up to what this message may still carry. Anything over
/// the limits is refused here, in front of the person who chose it, with one alert for the batch.
struct AttachMenu: View {
    /// How many more files this message may take.
    let remaining: Int
    /// The Mac takes attachments (or is not known yet not to).
    let available: Bool
    @Binding var loading: Bool
    let onPick: ([DraftFile]) -> Void

    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var browsingFiles = false
    @State private var takingPhoto = false
    @State private var failure: String?

    var body: some View {
        Menu {
            // A flag rather than a PhotosPicker in the menu: a picker inside a Menu never presents.
            Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            // Only where there is a camera to open: a simulator has none.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { takingPhoto = true }
            }
            Button("Files", systemImage: "folder") { browsingFiles = true }
            // `hasImages` asks without reading, so it raises no paste banner; the tap reads.
            if UIPasteboard.general.hasImages {
                Button("Paste", systemImage: "doc.on.clipboard") { pasteImages() }
            }
        } label: {
            Group {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "plus").font(.body.weight(.semibold)) }
            }
            .foregroundStyle(.secondary)
            .frame(width: controlTarget, height: controlTarget)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(loading || remaining <= 0 || !available)
        .accessibilityLabel(loading ? String(localized: "Loading attachments") : String(localized: "Attach photos or files"))
        .accessibilityHint(hint)
        .alert("Attachments couldn’t be added", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: max(1, remaining),
                      matching: .any(of: [.images, .videos]))
        .task(id: photos) { await loadPhotos() }
        .fileImporter(isPresented: $browsingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): loadFiles(urls)
            case .failure(let error):
                guard (error as NSError).code != NSUserCancelledError else { return }
                failure = String(localized: "Couldn’t open the selected files. Choose them again and check that they’re available on this device.")
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in
                Task {
                    await load([AttachmentSource(name: "photo.jpg") {
                        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                        try data.write(to: url)
                        return (url, nil)
                    }])
                }
            } onFailure: {
                failure = String(localized: "Couldn’t read the photo. Try taking it again.")
            }
            .ignoresSafeArea()
        }
    }

    private var hint: String {
        if !available { return String(localized: "Update Yorozu on your Mac to send files.") }
        if remaining <= 0 { return String(localized: "Remove an attachment to add another") }
        return String(localized: "Choose photos or files for this message")
    }

    private func loadPhotos() async {
        guard !photos.isEmpty else { return }
        let picked = photos
        defer { if photos == picked { photos = [] } }
        await load(picked.enumerated().map { index, item in
            let type = item.supportedContentTypes.first ?? .image
            let fallback = "photo-\(index + 1).\(type.preferredFilenameExtension ?? "jpg")"
            return AttachmentSource(name: fallback) {
                if let media = try? await item.loadTransferable(type: PickedMedia.self) { return (media.url, media.name) }
                guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
                let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try data.write(to: url)
                return (url, nil)
            }
        })
    }

    private func loadFiles(_ urls: [URL]) {
        Task {
            await load(urls.map { url in
                AttachmentSource(name: url.lastPathComponent) {
                    // A cloud document may download first: off the main actor, inside its security scope.
                    try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                        try FileManager.default.copyItem(at: url, to: copy)
                        return (copy, nil)
                    }.value
                }
            })
        }
    }

    private func pasteImages() {
        let providers = UIPasteboard.general.itemProviders
        Task {
            await load(providers.enumerated().compactMap { index, provider in
                guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else { return nil }
                let name = (provider.suggestedName ?? "pasted-\(index + 1)") + "." + (type.preferredFilenameExtension ?? "png")
                return AttachmentSource(name: name) { try await provider.copiedFile(of: type) }
            })
        }
    }

    /// Loads, stages and checks each source in order; one alert for whatever did not make it.
    private func load(_ sources: [AttachmentSource]) async {
        guard !sources.isEmpty else { return }
        loading = true
        defer { loading = false }
        var staged: [DraftFile] = []
        var unreadable: [String] = []
        var oversized: [String] = []
        let overCount = sources.count > remaining
        for source in sources.prefix(max(0, remaining)) {
            do {
                guard let (url, better) = try await source.load() else {
                    unreadable.append(source.name)
                    continue
                }
                let name = better ?? source.name
                staged.append(try await Task.detached(priority: .userInitiated) { try DraftFile.stage(url, name: name) }.value)
            } catch DraftFile.Refusal.tooLarge {
                oversized.append(source.name)
            } catch {
                unreadable.append(source.name)
            }
        }
        if !staged.isEmpty { onPick(staged) }
        var messages: [String] = []
        if !unreadable.isEmpty {
            messages.append(String(localized: "Couldn’t read: \(unreadable.joined(separator: ", ")). Choose another file."))
        }
        if !oversized.isEmpty {
            messages.append(String(localized: "Too large: \(oversized.joined(separator: ", ")). Each file must be 50 MB or smaller."))
        }
        if overCount { messages.append(String(localized: "A message can carry up to 10 files. Remove one to add another.")) }
        if !messages.isEmpty { failure = messages.joined(separator: "\n\n") }
    }
}

private extension NSItemProvider {
    /// A copy of the provider's file for `type`, which outlives the callback that hands it over.
    func copiedFile(of type: UTType) async throws -> (url: URL, name: String?)? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadFileRepresentation(for: type) { url, _, error in
                guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: (copy, nil))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// The system camera: `UIImagePickerController` is still the way to take one picture without a capture session.
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

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Full quality: staging reduces it, in one place for every way a picture gets in.
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 1) {
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

/// What is staged above the field: a horizontal run of tiles, each with its remove button and, for a
/// reduced image, "Send original".
struct StagedStrip: View {
    @Binding var files: [DraftFile]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: LayoutMetrics.inner) {
                ForEach($files) { $file in
                    StagedTile(file: $file) {
                        file.discard()
                        files.removeAll { $0.id == file.id }
                    }
                }
            }
            .padding(.vertical, LayoutMetrics.tight)
        }
        .scrollIndicators(.hidden)
    }
}

private struct StagedTile: View {
    @Binding var file: DraftFile
    let onRemove: () -> Void

    @State private var image: UIImage?

    /// The tile's picture: a custom component's own geometry.
    private static let side: CGFloat = 64
    private static let radius: CGFloat = 10
    private static let thumbnailPixels = 200

    var body: some View {
        VStack(spacing: LayoutMetrics.hair) {
            preview
                .frame(width: Self.side, height: Self.side)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .padding(LayoutMetrics.hair)
                            .frame(width: controlTarget, height: controlTarget, alignment: .topTrailing)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove \(file.chosen.name)"))
                }
            if file.original != nil {
                Button {
                    file.sendOriginal.toggle()
                } label: {
                    Label("Original", systemImage: file.sendOriginal ? "checkmark.circle.fill" : "circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(file.sendOriginal ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send original")
                .accessibilityValue(file.chosen.size)
                .accessibilityAddTraits(file.sendOriginal ? .isSelected : [])
            }
            Text(file.chosen.size)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .frame(width: Self.side)
        .task(id: file.chosen.url) {
            guard file.isImage else { return }
            let url = file.chosen.url
            let pixels = Self.thumbnailPixels
            image = await Task.detached { downsample(url, maxPixels: pixels) }.value
        }
    }

    @ViewBuilder private var preview: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
                .accessibilityLabel(Text("Attached image, \(file.chosen.name)"))
        } else {
            VStack(spacing: LayoutMetrics.hair) {
                Image(systemName: file.isImage ? "photo" : "doc").font(.title3).foregroundStyle(.secondary)
                Text(file.chosen.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, LayoutMetrics.hair)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Attached file, \(file.chosen.name), \(file.chosen.size)"))
        }
    }
}
