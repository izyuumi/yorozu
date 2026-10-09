import SwiftUI
import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ProjectXCore

// MARK: - Composer files (#316)

/// A file in the composer before it is sent. `temporary` files were made by Yorozu (pasted image data, a dropped image
/// without a file, Send as Text File) and are deleted once sent or removed; a picked or dropped file is never touched.
struct DraftFile: Identifiable, Equatable {
    let id = UUID()
    var url: URL, name: String, mime: String, bytes: Int64
    var temporary = false
    /// Images go downscaled to `imageMaxPixels` unless this is on.
    var sendOriginal = false
    var isImage: Bool { UTType(mimeType: mime)?.conforms(to: .image) ?? false }

    /// At most this many files per message, each at most `byteLimit` as sent (owner decision).
    static let countLimit = FileStore.maxFiles
    static let byteLimit = FileStore.maxBytes
    static var byteLimitText: String { size(byteLimit) }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes,countStyle: .file) }

    /// A regular readable file, or nil (a folder, a broken link).
    init?(url: URL,temporary: Bool = false) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey,.contentTypeKey]), values.isRegularFile == true else { return nil }
        self.url = url; name = url.lastPathComponent; bytes = Int64(values.fileSize ?? 0); self.temporary = temporary
        mime = (values.contentType ?? UTType(filenameExtension: url.pathExtension))?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Yorozu's own scratch files live under `$TMPDIR/Yorozu-attachments/<uuid>/<name>`, one folder each.
    static func temporaryURL(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Yorozu-attachments/\(UUID().uuidString)",isDirectory: true)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    /// Deletes a scratch file and its folder; anything outside the scratch root is left alone.
    static func discard(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        guard dir.deletingLastPathComponent().lastPathComponent == "Yorozu-attachments" else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// What `Engine.send` gets: each image downscaled into a scratch file unless Send original, then the limits checked on
    /// what would actually go. Returns the scratch files made so the caller deletes them once the send is done.
    static func prepare(_ files: [DraftFile]) throws -> (pending: [PendingFile], scratch: [URL]) {
        guard files.count <= countLimit else { throw Refusal(String(localized: "Up to \(countLimit) files per message.")) }
        var pending: [PendingFile] = [], scratch: [URL] = []
        do {
            for f in files {
                var file = PendingFile(url: f.url,name: f.name,mime: f.mime), bytes = f.bytes
                if f.isImage, !f.sendOriginal, let small = downscaledForSending(f.url,mime: f.mime) {
                    let name = (f.name as NSString).deletingPathExtension + "." + small.ext
                    let url = try temporaryURL(named: name); scratch.append(url)
                    try small.data.write(to: url)
                    file = PendingFile(url: url,name: name,mime: small.mime); bytes = Int64(small.data.count)
                }
                guard bytes <= byteLimit else { throw Refusal(String(localized: "“\(f.name)” is over \(byteLimitText). Files can be up to \(byteLimitText) each.")) }
                pending.append(file)
            }
        } catch { scratch.forEach(discard); throw error }
        return (pending,scratch)
    }
    /// A limit problem, shown above the composer in plain words.
    struct Refusal: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }
}

extension AppModel {
    /// Adds files to the composer, refusing folders, an 11th file and anything over the size limit that downscaling cannot
    /// shrink (images are checked again as sent).
    func attach(_ urls: [URL],temporary: Bool = false) {
        var problems: [String] = []
        for url in urls {
            guard let file = DraftFile(url: url,temporary: temporary) else {
                problems.append(String(localized: "“\(url.lastPathComponent)” isn't a file, so it can't be attached.")); continue
            }
            guard files.count < DraftFile.countLimit else {
                problems.append(String(localized: "Up to \(DraftFile.countLimit) files per message.")); if temporary { DraftFile.discard(url) }; continue
            }
            guard file.isImage || file.bytes <= DraftFile.byteLimit else {
                problems.append(String(localized: "“\(file.name)” is over \(DraftFile.byteLimitText). Files can be up to \(DraftFile.byteLimitText) each.")); if temporary { DraftFile.discard(url) }; continue
            }
            files.append(file)
        }
        fileNotice = problems.isEmpty ? nil : Array(NSOrderedSet(array: problems)).compactMap { $0 as? String }.joined(separator: " ")
    }
    func removeFile(_ id: DraftFile.ID) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        if files[i].temporary { DraftFile.discard(files[i].url) }
        files.remove(at: i); fileNotice = nil
    }
    /// Pasted or dropped onto the field: file URLs attach; image data with no text becomes a scratch image file. Text
    /// (with or without an image, as a spreadsheet cell copies) is left to the text view.
    func attach(from board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self],options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { attach(urls); return true }
        guard board.string(forType: .string) == nil else { return false }
        for (type,ext) in [(NSPasteboard.PasteboardType.png,"png"),(.tiff,"tiff")] {
            guard let data = board.data(forType: type) else { continue }
            do { let url = try DraftFile.temporaryURL(named: String(localized: "Pasted image") + "." + ext); try data.write(to: url); attach([url],temporary: true) }
            catch { fileNotice = error.localizedDescription }
            return true
        }
        return false
    }
    /// Dropped anywhere on the chat: files, or image data (a browser image) copied to a scratch file.
    func attach(dropped providers: [NSItemProvider]) -> Bool {
        var took = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                _ = p.loadObject(ofClass: URL.self) { url,_ in if let url { Task { @MainActor in self.attach([url]) } } }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                took = true
                let name = p.suggestedName
                _ = p.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url,_ in
                    // The provider deletes its file when this returns, so copy it now.
                    guard let url, let copy = try? DraftFile.temporaryURL(named: name.map { $0 + "." + url.pathExtension } ?? url.lastPathComponent),
                          (try? FileManager.default.copyItem(at: url,to: copy)) != nil else { return }
                    Task { @MainActor in self.attach([copy],temporary: true) }
                }
            }
        }
        return took
    }
    /// The file picker. The popover is transient and closes behind the panel, so it reopens once the panel is done.
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.prompt = String(localized: "Attach")
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK { self?.attach(panel.urls) }
                AttentionCenter.shared.onOpen?()
            }
        }
    }
    /// Send as Text File (#311 Q12): the over-limit draft becomes a `.txt` attachment and the field empties.
    func draftToTextFile() {
        do {
            let url = try DraftFile.temporaryURL(named: String(localized: "Message") + ".txt")
            try Data(draft.utf8).write(to: url)
            let before = files.count
            attach([url],temporary: true)
            if files.count > before { draft = "" }
        } catch { fileNotice = error.localizedDescription }
    }
}

/// One composer file: its thumbnail or icon, name, size, Send original for an image, and remove.
struct DraftFileRow: View {
    let file: DraftFile
    @Binding var sendOriginal: Bool
    let remove: () -> Void
    private enum Metrics { static let icon: CGFloat = 28, radius: CGFloat = 8, iconRadius: CGFloat = 4 }
    var body: some View {
        HStack(spacing: 8) {
            Thumbnail(url: file.url,key: nil,side: Metrics.icon,mime: file.mime)
                .frame(width: Metrics.icon,height: Metrics.icon).clipShape(RoundedRectangle(cornerRadius: Metrics.iconRadius,style: .continuous))
            VStack(alignment: .leading,spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(DraftFile.size(file.bytes)).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity,alignment: .leading)
            if file.isImage {
                Toggle("Send original",isOn: $sendOriginal).toggleStyle(.checkbox).controlSize(.small).font(.caption)
                    .help(Text("Send at full size instead of \(imageMaxPixels) px on the long edge"))
            }
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove").accessibilityLabel(Text("Remove \(file.name)"))
        }
        .font(.callout).padding(.horizontal,8).padding(.vertical,5)
        .background(.background,in: RoundedRectangle(cornerRadius: Metrics.radius,style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metrics.radius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
    }
}

// MARK: - Timeline files

/// The files on a user message or a result: images as previews, anything else as a file row.
struct MessageFiles: View {
    let files: [Attachment]
    let locate: (Attachment) async -> URL?
    var body: some View {
        VStack(alignment: .leading,spacing: 6) { ForEach(files) { AttachmentView(file: $0,locate: locate) } }
    }
}

/// One stored file. Click opens Quick Look; the context menu adds Show in Finder. A file deleted since reads
/// "File no longer available".
private struct AttachmentView: View {
    let file: Attachment
    let locate: (Attachment) async -> URL?
    @State private var url: URL?
    @State private var missing = false
    private enum Metrics { static let imageHeight: CGFloat = 180, thumbSide: CGFloat = 360, icon: CGFloat = 28, radius: CGFloat = 9 }
    private var isImage: Bool { UTType(mimeType: file.mime)?.conforms(to: .image) ?? false }
    var body: some View {
        Group {
            if missing { missingRow }
            else if isImage { image }
            else { row }
        }
        .task(id: file.id) { url = await locate(file); missing = url == nil }
    }

    private var image: some View {
        Button(action: open) {
            VStack(alignment: .leading,spacing: 4) {
                Group {
                    if let url { Thumbnail(url: url,key: file.id,side: Metrics.thumbSide,mime: file.mime).scaledToFit() }
                    else { Color.clear }
                }
                .frame(maxWidth: .infinity,maxHeight: Metrics.imageHeight)
                .background(.quaternary.opacity(0.6),in: RoundedRectangle(cornerRadius: Metrics.radius,style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius,style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Metrics.radius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
                HStack(spacing: 8) {
                    Text(DraftFile.size(file.bytes))
                    Spacer(minLength: 0)
                    Text(file.name).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain).contextMenu { menu }.help(Text("Quick Look"))
        .accessibilityLabel(Text("Image \(file.name), \(DraftFile.size(file.bytes))")).accessibilityHint(Text("Opens Quick Look"))
    }

    private var row: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: file.mime) ?? .data)).resizable().scaledToFit()
                    .frame(width: Metrics.icon,height: Metrics.icon).accessibilityHidden(true)
                VStack(alignment: .leading,spacing: 1) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(kind + " · " + DraftFile.size(file.bytes)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity,alignment: .leading)
            }.fileRow(radius: Metrics.radius)
        }
        .buttonStyle(.plain).contextMenu { menu }.help(Text("Quick Look"))
        .accessibilityElement(children: .combine).accessibilityHint(Text("Opens Quick Look"))
    }

    private var missingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.ellipsis").font(.title3).foregroundStyle(.secondary).frame(width: Metrics.icon).accessibilityHidden(true)
            VStack(alignment: .leading,spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Text("File no longer available").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity,alignment: .leading)
        }.fileRow(radius: Metrics.radius).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var menu: some View {
        Button("Quick Look",action: open)
        Button("Show in Finder") { if let url = current() { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }
    private var kind: String { UTType(mimeType: file.mime)?.localizedDescription ?? file.mime }
    /// The file, checked again at use: it may have been deleted since the row appeared.
    private func current() -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { missing = true; return nil }
        return url
    }
    private func open() { if let url = current() { QuickLook.shared.show(url) } }
}

private extension View {
    func fileRow(radius: CGFloat) -> some View {
        font(.callout).padding(.horizontal,8).padding(.vertical,6).frame(maxWidth: .infinity,alignment: .leading)
            .background(.quaternary.opacity(0.6),in: RoundedRectangle(cornerRadius: radius,style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
            .contentShape(Rectangle())
    }
}

/// A QuickLookThumbnailing preview, or the file type's icon until (or unless) one is made. With a `key` the thumbnail is
/// cached on disk under `~/Library/Caches/<bundle id>/thumbs/` (rebuildable).
struct Thumbnail: View {
    let url: URL, key: String?, side: CGFloat, mime: String
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() }
            else { Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: mime) ?? .data)).resizable().scaledToFit() }
        }
        .task(id: url) { image = await Self.load(url,key: key,side: side,scale: scale) }
    }
    static let cache: URL? = (try? FileManager.default.url(for: .cachesDirectory,in: .userDomainMask,appropriateFor: nil,create: true))?
        .appendingPathComponent((Bundle.main.bundleIdentifier ?? "to.yumi.yorozu") + "/thumbs",isDirectory: true)
    private static func load(_ url: URL,key: String?,side: CGFloat,scale: CGFloat) async -> NSImage? {
        let file = key.flatMap { k in cache?.appendingPathComponent("\(k)-\(Int(side * scale)).png") }
        if let file, let cached = NSImage(contentsOf: file) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url,size: CGSize(width: side,height: side),scale: scale,representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        if let file, let dir = cache {
            try? FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
            if let dest = CGImageDestinationCreateWithURL(file as CFURL,UTType.png.identifier as CFString,1,nil) {
                CGImageDestinationAddImage(dest,rep.cgImage,nil); CGImageDestinationFinalize(dest)
            }
        }
        return rep.nsImage
    }
}

/// The shared Quick Look panel, showing one file.
@MainActor final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var url: URL?
    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!,previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}
