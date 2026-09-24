import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if canImport(LinkPresentation)
    import LinkPresentation
#endif

/// What a link preview row draws: the page's own title, the host it came from, and its icon.
/// Small enough to keep whole on disk — a favicon is a few kilobytes and a title is a line.
public struct LinkPreview: Codable, Equatable, Sendable {
    public var title: String
    public var host: String
    /// The site icon as it was fetched, in whatever image format it was offered in. Nil when the
    /// site has none, which is a row with a globe on it rather than no row.
    public var icon: Data?

    public init(title: String, host: String, icon: Data? = nil) {
        self.title = title
        self.host = host
        self.icon = icon
    }
}

/// The first bare URL in a message, or nil when there is none.
///
/// "Bare" means pasted as itself: a URL that is the destination of a Markdown link is already
/// drawn as that link's text, and one inside code is being quoted rather than linked to, so
/// neither earns a preview. Both are removed before looking, which is the whole of the parsing —
/// the detector does the rest.
public func firstLink(in text: String) -> URL? {
    var stripped = text
    for pattern in [
        // Fenced blocks first, so a fence containing backticks is not half-eaten by the next.
        "(?s)```.*?```",
        "`[^`]*`",
        // The destination of a Markdown link or image, the text of which stays behind.
        "\\]\\([^)]*\\)",
        // An autolink: pointed brackets are Markdown asking for it to be linked, not a bare URL.
        "<[^>\\s]+>",
    ] {
        stripped = stripped.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(stripped.startIndex..., in: stripped)
    let match = detector?.firstMatch(in: stripped, range: range)?.url
    // Only the web: a `mailto:` or a `tel:` has no page behind it to preview.
    guard let match, let scheme = match.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return nil }
    return match
}

/// Fetches and remembers what a link looks like. Memory first, then a file per URL in the
/// caches directory, then the network — and never more than once per URL per launch, however
/// many times the thread redraws.
///
/// Nothing here blocks a thread from rendering: a bubble draws immediately and the row appears
/// under it if and when the metadata lands. A failure is silent and remembered as a failure, so
/// a dead link is not re-fetched on every scroll.
@MainActor
@Observable
public final class LinkPreviewStore {
    /// How long a page has to answer before the row is given up on.
    public static let timeout: TimeInterval = 5

    public static let shared = LinkPreviewStore()

    private var memory: [URL: LinkPreview] = [:]
    /// URLs already tried and not worth trying again this launch.
    private var failed: Set<URL> = []
    private var loading: Set<URL> = []
    private let directory: URL
    private let fetch: @MainActor (URL) async -> LinkPreview?

    /// `fetch` is injectable so the cache can be tested without a network: the default is
    /// `LPMetadataProvider`, which is the only thing here that touches one.
    public init(
        directory: URL = URL.cachesDirectory.appending(path: "Yorozu/link-previews"),
        fetch: @escaping @MainActor (URL) async -> LinkPreview? = LinkPreviewStore.metadata
    ) {
        self.directory = directory
        self.fetch = fetch
    }

    /// What is known about a URL right now, without going and finding out. This is what a view
    /// body reads.
    public func cached(_ url: URL) -> LinkPreview? { memory[url] }

    /// Fills in ``cached(_:)`` from disk or from the site, unless it is already known or has
    /// already failed. Safe to call from a `.task`: a second call while the first is in flight
    /// does nothing.
    public func load(_ url: URL) async {
        guard memory[url] == nil, !failed.contains(url), loading.insert(url).inserted else { return }
        defer { loading.remove(url) }
        if let stored = readFromDisk(url) {
            memory[url] = stored
            return
        }
        guard let preview = await fetch(url) else {
            failed.insert(url)
            return
        }
        memory[url] = preview
        writeToDisk(preview, for: url)
    }

    /// Test-only: puts a preview in as though it had just been fetched, so a screenshot of the
    /// row does not depend on a network or on a site staying the same.
    public func preload(_ preview: LinkPreview, for url: URL) { memory[url] = preview }

    /// The file a URL is cached in. Named by the hash rather than by the URL: the caches
    /// directory is not sealed the way the thread cache is, and a directory listing of the
    /// links somebody was sent would be a transcript of its own.
    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private func readFromDisk(_ url: URL) -> LinkPreview? {
        guard let raw = try? Data(contentsOf: file(for: url)) else { return nil }
        return try? JSONDecoder().decode(LinkPreview.self, from: raw)
    }

    private func writeToDisk(_ preview: LinkPreview, for url: URL) {
        guard let raw = try? JSONEncoder().encode(preview) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? raw.write(to: file(for: url), options: .atomic)
    }

    /// The on-device fetch: `LPMetadataProvider` is the same thing Messages uses, so a page is
    /// read by the system's own fetcher rather than by anything of ours, and nothing about the
    /// link leaves the phone except the request to the site itself.
    public static func metadata(for url: URL) async -> LinkPreview? {
        #if canImport(LinkPresentation)
            let provider = LPMetadataProvider()
            provider.timeout = timeout
            guard let data = try? await provider.startFetchingMetadata(for: url) else { return nil }
            let host = url.host()?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
            let title = data.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let icon = await iconData(from: data.iconProvider ?? data.imageProvider)
            // A page that gave us neither a title nor an icon has nothing to show.
            guard !title.isEmpty || icon != nil else { return nil }
            return LinkPreview(
                title: title.isEmpty ? (host ?? url.absoluteString) : title,
                host: host ?? url.absoluteString,
                icon: icon
            )
        #else
            return nil
        #endif
    }

    #if canImport(LinkPresentation)
        private static func iconData(from provider: NSItemProvider?) async -> Data? {
            guard let provider else { return nil }
            return await withCheckedContinuation { resume in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                    data, _ in
                    resume.resume(returning: data)
                }
            }
        }
    #endif
}

/// The compact row under an agent's message: the site's icon, its title, and the host it is on.
/// It is not there at all until the metadata has landed, so nothing about the thread moves while
/// a slow site is being waited for — and a site that never answers leaves no gap behind.
public struct LinkPreviewRow: View {
    private let url: URL
    private let store: LinkPreviewStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ScaledMetric(relativeTo: .caption) private var iconSize = 16

    @MainActor public init(url: URL, store: LinkPreviewStore = .shared) {
        self.url = url
        self.store = store
    }

    public var body: some View {
        Group {
            if let preview = store.cached(url) {
                Link(destination: url) {
                    HStack(spacing: LayoutMetrics.inner) {
                        icon(preview)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preview.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(preview.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, LayoutMetrics.stack)
                    .padding(.vertical, LayoutMetrics.inner)
                    .frame(minHeight: controlTarget)
                }
                .buttonStyle(.plain)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
                .frame(maxWidth: 420, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Link: \(preview.title), \(preview.host)")
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .task(id: url) { await store.load(url) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.cached(url))
    }

    @ViewBuilder private func icon(_ preview: LinkPreview) -> some View {
        if let bytes = preview.icon, let image = Image.from(data: bytes) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
        }
    }
}
