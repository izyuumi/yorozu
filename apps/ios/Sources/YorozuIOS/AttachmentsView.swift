import QuickLook
import SwiftUI
import UIKit

// v1 packages/shared-swift MessageBubble.swift's AttachmentsView, for files that live on the Mac:
// images as thumbnails that download when shown, other files as rows; a tap downloads the full file
// and opens it in Quick Look, or the share sheet for a type Quick Look cannot show.

/// A message's or a worker event's files. Its width comes from the row it sits in.
struct AttachmentsView: View {
    let files: [AttachmentInfo]

    @Environment(AttachmentFiles.self) private var store: AttachmentFiles?
    @State private var sharing: SharedFile?

    /// The tallest a lone image is drawn; a grid's tiles are square, two to a row.
    private static let singleMaxHeight: CGFloat = 320
    private static let gridSpacing: CGFloat = 3
    private static let radius: CGFloat = 12
    /// A placeholder's shape until the thumbnail has arrived.
    private static let placeholderAspect: CGFloat = 4 / 3

    var body: some View {
        let images = files.filter(\.isImage)
        let others = files.filter { !$0.isImage }
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            if images.count == 1, let image = images.first {
                imageButton(image, single: true)
            } else if !images.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing), count: 2), spacing: Self.gridSpacing) {
                    ForEach(images) { imageButton($0, single: false) }
                }
            }
            ForEach(others) { fileRow($0) }
        }
        .sheet(item: $sharing) { ShareSheet(url: $0.url).ignoresSafeArea() }
    }

    private func missing(_ info: AttachmentInfo) -> Bool { store?.missing.contains(info.cacheKey) == true }
    private func progress(_ info: AttachmentInfo) -> Double? { store?.progress[info.cacheKey] }

    @ViewBuilder private func imageButton(_ info: AttachmentInfo, single: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        if missing(info) {
            unavailableRow(info)
        } else {
            Button { open(info) } label: {
                Group {
                    if let image = store?.thumbnails[info.cacheKey] {
                        if single {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxHeight: Self.singleMaxHeight, alignment: .leading)
                        } else {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                        }
                    } else {
                        Rectangle().fill(.fill.tertiary)
                            .aspectRatio(single ? Self.placeholderAspect : 1, contentMode: .fit)
                            .frame(maxHeight: single ? Self.singleMaxHeight : nil)
                            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
                }
                .overlay { if let value = progress(info) { ProgressView(value: value).progressViewStyle(.circular).tint(.white) } }
                .clipShape(shape)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .task { await store?.loadThumbnail(info) }
            .accessibilityLabel(Text("Attached image, \(info.name)"))
            .accessibilityHint("Opens the picture")
        }
    }

    @ViewBuilder private func fileRow(_ info: AttachmentInfo) -> some View {
        if missing(info) {
            unavailableRow(info)
        } else {
            Button { open(info) } label: {
                HStack(spacing: LayoutMetrics.inner) {
                    Image(systemName: "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                        Text(info.name).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "\(info.typeName) · \(info.size)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let value = progress(info) { ProgressView(value: value) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(LayoutMetrics.inner)
                .frame(minHeight: controlTarget)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Attached file, \(info.name), \(info.size)"))
            .accessibilityValue(progress(info).map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
            .accessibilityHint("Downloads and opens the file")
        }
    }

    /// The file is gone from the Mac (deleted in Finder): the name stays, the tap goes.
    private func unavailableRow(_ info: AttachmentInfo) -> some View {
        Label {
            VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                Text(info.name).lineLimit(1).truncationMode(.middle)
                Text("File no longer available").font(.caption)
            }
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(LayoutMetrics.inner)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func open(_ info: AttachmentInfo) {
        Task {
            guard let url = await store?.open(info) else { return }
            if QLPreviewController.canPreview(url as NSURL) { FilePreview.present(url) } else { sharing = SharedFile(url: url) }
        }
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for one file: Save Image, Save to Files, AirDrop, other apps.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Quick Look presented by UIKit, as Files and Photos do: the image can be pinched and panned, and a swipe down
/// closes it. SwiftUI's `quickLookPreview` hosts it in a cover without that dismissal.
private final class FilePreview: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    private init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func present(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(FilePreview(url: url), animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
}
