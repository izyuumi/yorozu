import QuickLookThumbnailing
import SwiftUI

/// A file's Quick Look thumbnail, fitted into a square of `side` points: a picture, a PDF's first page, or the file
/// type's icon while there is none. The app (file rows in a conversation) and the share extension (the preview of what
/// is being sent) both compile this folder.
struct FileThumbnail: View {
    let url: URL
    let side: CGFloat
    /// Fills the square, cropping, rather than fitting inside it.
    var fill = false
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: scale).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                representationTypes: .all)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        }
        .accessibilityHidden(true)
    }
}
