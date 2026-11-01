import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import YorozuWire
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AttachMenu: View {
    let limit: Int
    let onStage: ([ChatAttachment]) -> Void

    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var browsingFiles = false
    @State private var takingPhoto = false
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        Menu {
            Button(String(localized: "Photo Library"), systemImage: "photo.on.rectangle") { choosingPhotos = true }
            #if os(iOS)
            Button(String(localized: "Take Photo"), systemImage: "camera") { takingPhoto = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            #endif
            Button(String(localized: "Files"), systemImage: "folder") { browsingFiles = true }
        } label: {
            Group {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "plus").textStyle(.body, weight: .semibold) }
            }
            .foregroundStyle(.secondary)
            .composerControl()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Attach"))
        .accessibilityLabel(Text("Attach"))
        .accessibilityIdentifier("composer.attach")
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
        .fileImporter(isPresented: $browsingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            stage(urls.map { url in { try AttachmentStaging.stage(file: url, limit: limit) } })
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                guard let image, let data = image.jpegData(compressionQuality: 0.85) else { return }
                stage([{ try AttachmentStaging.stage(image: data, name: "Photo", limit: limit) }])
            }
            .ignoresSafeArea()
        }
        #endif
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

#if os(iOS)
private struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, dismiss: dismiss) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        let dismiss: DismissAction

        init(onFinish: @escaping (UIImage?) -> Void, dismiss: DismissAction) {
            self.onFinish = onFinish
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
#endif

struct StagedFiles: View {
    let files: [ChatAttachment]
    var automation: CronJob? = nil
    var onRemoveAutomation: () -> Void = {}
    let onRemove: (ChatAttachment) -> Void
    @ScaledMetric private var previewSide: CGFloat = 56
    @Environment(\.textZoom) private var zoom

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LayoutMetrics.tight) {
                if let automation {
                    HStack(spacing: LayoutMetrics.tight) {
                        Image(systemName: "clock")
                        Text(automation.name).lineLimit(1).truncationMode(.middle)
                        Text(automation.localizedScheduleText).foregroundStyle(.secondary).lineLimit(1)
                        Button(action: onRemoveAutomation) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Remove \(automation.name)"))
                        .accessibilityLabel(Text("Remove \(automation.name)"))
                    }
                    .textStyle(.footnote)
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

    private func preview(_ file: ChatAttachment, url: URL) -> some View {
        FileThumbnail(url: url, side: previewSide * zoom, fill: true)
            .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.inner, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button { onRemove(file) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(LayoutMetrics.tight)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Remove \(file.name)"))
                .accessibilityLabel(Text("Remove \(file.name)"))
            }
            .padding(.vertical, LayoutMetrics.tight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(file.name))
    }

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
            .help(String(localized: "Remove \(file.name)"))
            .accessibilityLabel(Text("Remove \(file.name)"))
        }
        .textStyle(.footnote)
        .padding(.horizontal, LayoutMetrics.inner)
        .padding(.vertical, LayoutMetrics.tight)
        .background(.fill.tertiary, in: Capsule())
    }
}

struct AttachmentList: View {
    let model: AppModel
    let attachments: [ChatAttachment]
    let alignment: HorizontalAlignment

    #if os(iOS)
    private struct Previewed: Identifiable {
        let id: String
        let url: URL
    }

    @State private var previewed: Previewed?
    @Namespace private var zoom
    #endif

    var body: some View {
        VStack(alignment: alignment, spacing: LayoutMetrics.tight) {
            ForEach(attachments) { attachment in
                Group {
                    if attachment.isImage {
                        ImageAttachment(model: model, attachment: attachment, open: open)
                    } else {
                        FileAttachment(model: model, attachment: attachment, open: open)
                    }
                }
                #if os(iOS)
                .matchedTransitionSource(id: attachment.id, in: zoom)
                #endif
                .contextMenu {
                    if let url = AttachmentFiles.local(attachment) {
                        ShareLink(item: url) { Label(String(localized: "Share"), systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $previewed) { item in
            QuickLookPreview(url: item.url) { previewed = nil }
                .ignoresSafeArea()
                .navigationTransition(.zoom(sourceID: item.id, in: zoom))
        }
        #endif
    }

    private func open(_ attachment: ChatAttachment) {
        #if os(macOS)
        if AttachmentFiles.withLocal(attachment, { NSWorkspace.shared.open($0) ? true : nil }) == nil {
            model.fetch(attachment)
        }
        #else
        guard let url = AttachmentFiles.local(attachment) else { return model.fetch(attachment) }
        previewed = Previewed(id: attachment.id, url: url)
        #endif
    }
}

#if os(iOS)
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        let coordinator = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in coordinator.done() })
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        context.coordinator.done = done
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        (navigation.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url, done: done) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        var done: () -> Void

        init(url: URL, done: @escaping () -> Void) {
            self.url = url
            self.done = done
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
#endif

private enum FileState {
    case local(URL), moving(Double), failed(String), refused(String), remote

    @MainActor init(_ attachment: ChatAttachment, model: AppModel) {
        if let failure = attachment.failure { self = .refused(failure) }
        else if let progress = model.transfers.progress[attachment.id] { self = .moving(progress) }
        else if let url = AttachmentFiles.local(attachment) { self = .local(url) }
        else if let failure = model.transfers.failures[attachment.id] { self = .failed(failure) }
        else { self = .remote }
    }
}

private struct FileAttachment: View {
    let model: AppModel
    let attachment: ChatAttachment
    let open: (ChatAttachment) -> Void
    @ScaledMetric(relativeTo: .title2) private var thumbnailSide: CGFloat = 40
    @Environment(\.textZoom) private var zoom

    var body: some View {
        let state = FileState(attachment, model: model)
        Button { open(attachment) } label: {
            HStack(spacing: LayoutMetrics.inner) {
                icon(state).textStyle(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.name).lineLimit(1).truncationMode(.middle)
                    Text(detail(state)).textStyle(.caption).foregroundStyle(.secondary).lineLimit(2)
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
        case .local(let url): FileThumbnail(url: url, side: thumbnailSide * zoom)
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

private struct ImageAttachment: View {
    let model: AppModel
    let attachment: ChatAttachment
    let open: (ChatAttachment) -> Void

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
                FileAttachment(model: model, attachment: attachment, open: open)
            }
        }
        .task(id: AttachmentFiles.local(attachment)?.path) {
            guard AttachmentFiles.local(attachment) != nil else {
                if case .remote = state { model.fetch(attachment) }
                return
            }
            image = await Task.detached { [attachment] in
                AttachmentFiles.withLocal(attachment) { Self.thumbnail($0) }
            }.value
        }
    }

    nonisolated private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ] as CFDictionary)
    }
}
