import QuickLookThumbnailing
import SwiftUI

struct FileThumbnail: View {
    let url: URL
    let side: CGFloat
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
