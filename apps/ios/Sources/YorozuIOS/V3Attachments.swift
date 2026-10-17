import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import YorozuWire
#if os(macOS)
import AppKit
#endif

// Attachments in the chat (#430): the composer's + and staged files, and the files on messages and replies.

/// The composer's +: photos from the library and files from Files (or the Finder), each checked against the host's limit
/// before anything is copied, so a file over it is refused here with its size and the limit.
struct V3AttachMenu: View {
    let limit: Int
    let onStage: ([ChatAttachment]) -> Void

    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var browsingFiles = false
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        Menu {
            // A flag rather than a PhotosPicker in the menu: a picker inside a Menu never presents.
            Button(String(localized: "Photo Library"), systemImage: "photo.on.rectangle") { choosingPhotos = true }
            Button(String(localized: "Files"), systemImage: "folder") { browsingFiles = true }
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
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Attach"))
        .accessibilityIdentifier("composer.attach")
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
        .fileImporter(isPresented: $browsingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            stage(urls.map { url in { try AttachmentStaging.stage(file: url, limit: limit) } })
        }
        .onChange(of: photos) {
            let items = photos
            photos = []
            guard !items.isEmpty else { return }
            loading = true
            Task {
                var jobs: [() throws -> ChatAttachment] = []
                for (n, item) in items.enumerated() {
                    let data = try? await item.loadTransferable(type: Data.self)
                    let name = "Photo \(n + 1)"
                    jobs.append {
                        guard let data else { throw AttachmentStaging.Failure.unreadable(name: name) }
                        return try AttachmentStaging.stage(image: data, name: name, limit: limit)
                    }
                }
                loading = false
                stage(jobs)
            }
        }
        .alert(String(localized: "Can’t attach"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// Stages what it can; one alert names everything refused.
    private func stage(_ jobs: [() throws -> ChatAttachment]) {
        var staged: [ChatAttachment] = []
        var refused: [String] = []
        for job in jobs {
            do { staged.append(try job()) } catch { refused.append(error.localizedDescription) }
        }
        if !staged.isEmpty { onStage(staged) }
        if !refused.isEmpty { failure = refused.joined(separator: "\n") }
    }
}

/// Files waiting in the composer, each with a remove button.
struct V3StagedFiles: View {
    let files: [ChatAttachment]
    /// An automation from "Edit in Chat", first in the row.
    var automation: V3CronJob? = nil
    var onRemoveAutomation: () -> Void = {}
    let onRemove: (ChatAttachment) -> Void
    /// A staged picture's preview, scaled with the text.
    @ScaledMetric private var previewSide: CGFloat = 56

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LayoutMetrics.tight) {
                if let automation {
                    HStack(spacing: LayoutMetrics.tight) {
                        Image(systemName: "clock")
                        Text(automation.name).lineLimit(1).truncationMode(.middle)
                        Text(automation.scheduleText).foregroundStyle(.secondary).lineLimit(1)
                        Button(action: onRemoveAutomation) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove \(automation.name)"))
                    }
                    .font(.footnote)
                    .padding(.horizontal, LayoutMetrics.inner)
                    .padding(.vertical, LayoutMetrics.tight)
                    .background(.fill.tertiary, in: Capsule())
                }
                ForEach(files) { file in
                    if file.isImage, let url = AttachmentFiles.local(file) {
                        preview(file, url: url)
                    } else {
                        chip(file)
                    }
                }
            }
            .padding(.horizontal, LayoutMetrics.inner)
        }
    }

    /// A picture: its preview, the remove button on its corner (owner, 2026-10-17).
    private func preview(_ file: ChatAttachment, url: URL) -> some View {
        FileThumbnail(url: url, side: previewSide, fill: true)
            .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.inner, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button { onRemove(file) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(LayoutMetrics.tight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(file.name)"))
            }
            .padding(.vertical, LayoutMetrics.tight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(file.name))
    }

    /// Any other file: its name and size.
    private func chip(_ file: ChatAttachment) -> some View {
        HStack(spacing: LayoutMetrics.tight) {
            Image(systemName: file.isImage ? "photo" : "doc")
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Text(AttachmentStaging.Failure.format(file.size)).foregroundStyle(.secondary)
            Button {
                onRemove(file)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(file.name)"))
        }
        .font(.footnote)
        .padding(.horizontal, LayoutMetrics.inner)
        .padding(.vertical, LayoutMetrics.tight)
        .background(.fill.tertiary, in: Capsule())
    }
}

/// A message's or reply's files: pictures inline, other files as rows. A reply's files download only when shown
/// (pictures) or tapped (files); Quick Look opens them on iPhone and iPad, the default app on the Mac.
struct V3AttachmentList: View {
    let model: V3Model
    let attachments: [ChatAttachment]
    let alignment: HorizontalAlignment

    @State private var preview: URL?

    var body: some View {
        VStack(alignment: alignment, spacing: LayoutMetrics.tight) {
            ForEach(attachments) { attachment in
                Group {
                    if attachment.isImage {
                        V3ImageAttachment(model: model, attachment: attachment, open: open)
                    } else {
                        V3FileAttachment(model: model, attachment: attachment, open: open)
                    }
                }
                .contextMenu {
                    if let url = AttachmentFiles.local(attachment) {
                        ShareLink(item: url) { Label(String(localized: "Share"), systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
        #if os(iOS)
        .quickLookPreview($preview)
        #endif
    }

    private func open(_ attachment: ChatAttachment) {
        guard let url = AttachmentFiles.local(attachment) else { return model.fetch(attachment) }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        preview = url
        #endif
    }
}

/// Where a file stands: here, moving, failed, or waiting for a tap.
private enum FileState {
    case local(URL), moving(Double), failed(String), refused(String), remote

    @MainActor init(_ attachment: ChatAttachment, model: V3Model) {
        if let failure = attachment.failure { self = .refused(failure) }
        else if let progress = model.transfers.progress[attachment.id] { self = .moving(progress) }
        else if let url = AttachmentFiles.local(attachment) { self = .local(url) }
        else if let failure = model.transfers.failures[attachment.id] { self = .failed(failure) }
        else { self = .remote }
    }
}

private struct V3FileAttachment: View {
    let model: V3Model
    let attachment: ChatAttachment
    let open: (ChatAttachment) -> Void
    /// A downloaded file's thumbnail (a PDF's first page), scaled with the text.
    @ScaledMetric(relativeTo: .title2) private var thumbnailSide: CGFloat = 40

    var body: some View {
        let state = FileState(attachment, model: model)
        Button { open(attachment) } label: {
            HStack(spacing: LayoutMetrics.inner) {
                icon(state).font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.name).lineLimit(1).truncationMode(.middle)
                    Text(detail(state)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(LayoutMetrics.inner)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled({ if case .refused = state { true } else { false } }())
        .accessibilityLabel(Text("\(attachment.name), \(detail(state))"))
    }

    @ViewBuilder private func icon(_ state: FileState) -> some View {
        switch state {
        case .moving(let progress): ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
        case .failed, .refused: Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
        case .remote: Image(systemName: "arrow.down.circle")
        case .local(let url): FileThumbnail(url: url, side: thumbnailSide)
        }
    }

    private func detail(_ state: FileState) -> String {
        let size = AttachmentStaging.Failure.format(attachment.size)
        switch state {
        case .local: return size
        case .moving: return String(localized: "\(size) · Transferring…")
        case .failed(let why): return String(localized: "\(size) · \(why) Tap to try again.")
        case .refused(let why): return String(localized: "Not sent: \(why)")
        case .remote: return String(localized: "\(size) · Tap to download")
        }
    }
}

/// A picture, fitted to the row; downloaded as soon as it is on screen.
private struct V3ImageAttachment: View {
    let model: V3Model
    let attachment: ChatAttachment
    let open: (ChatAttachment) -> Void

    /// The tallest a picture stands in the conversation; the rest is a tap away.
    private let maxHeight: CGFloat = 320
    @State private var image: CGImage?

    var body: some View {
        let state = FileState(attachment, model: model)
        Group {
            if let image {
                Button { open(attachment) } label: {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: maxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(attachment.name))
            } else {
                V3FileAttachment(model: model, attachment: attachment, open: open)
            }
        }
        .task(id: AttachmentFiles.local(attachment)?.path) {
            guard let url = AttachmentFiles.local(attachment) else {
                if case .remote = state { model.fetch(attachment) }
                return
            }
            image = await Task.detached { Self.thumbnail(url) }.value
        }
    }

    /// Sized for a screen, never decoded whole.
    nonisolated private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ] as CFDictionary)
    }
}
