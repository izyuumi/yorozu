import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A raw input cap, before image downsampling. Transport limits remain 5 MB/file, 10 files.
/// File reads use a bounded read rather than mapping an arbitrarily large document.
func readAttachmentFile(_ url: URL) throws -> Data {
    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
    guard let size = values.fileSize, size <= AttachmentAcquisition.maxSourceBytes else {
        throw CocoaError(.fileReadTooLarge)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: AttachmentAcquisition.maxSourceBytes + 1) ?? Data()
    guard data.count <= AttachmentAcquisition.maxSourceBytes else { throw CocoaError(.fileReadTooLarge) }
    return data
}

/// Metadata-only checks. Content is read exclusively from the user's Paste action.
@MainActor func pasteboardHasAttachments() -> Bool {
    #if os(iOS)
    return clipboardFileType(UIPasteboard.general.types) != nil
    #else
    let board = NSPasteboard.general
    guard let type = clipboardFileType((board.types ?? []).map(\.rawValue)) else { return pasteboardHasImages() }
    return !type.conforms(to: .image) || board.availableType(from: [.string]) == nil
    #endif
}

/// Prefer a file's representation to incidental text (e.g. a filename copied in Files).
/// Plain text and web links keep the native text editor's insertion/selection behavior.
func clipboardFileType(_ identifiers: [String]) -> UTType? {
    let types = identifiers.compactMap { UTType($0) }
    return types.first {
        $0 != .fileURL && $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url)
    } ?? types.first { $0 == .fileURL }
}

@MainActor func clipboardAttachmentSources() -> [AttachmentSource] {
    #if os(iOS)
    return clipboardAttachmentSources(UIPasteboard.general.itemProviders)
    #else
    let board = NSPasteboard.general
    if board.availableType(from: [.fileURL]) != nil {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { url in
            AttachmentSource(name: url.lastPathComponent,
                mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                load: { try await Task.detached { try readAttachmentFile(url) }.value })
        }
    }
    let representations = (board.pasteboardItems ?? []).compactMap { item -> AttachmentSource? in
        guard let type = clipboardFileType(item.types.map(\.rawValue)),
              !type.conforms(to: .image) || item.types.contains(.string) == false else { return nil }
        return AttachmentSource(name: "Attachment.\(type.preferredFilenameExtension ?? "bin")",
            mime: type.preferredMIMEType ?? "application/octet-stream", load: { item.data(forType: .init(type.identifier)) })
    }
    if !representations.isEmpty { return representations }
    return pasteboardImagePicks().map { pick in
        AttachmentSource(name: pick.name, mime: pick.mime, load: { pick.bytes })
    }
    #endif
}

#if os(iOS)
@MainActor func clipboardAttachmentSources(_ providers: [NSItemProvider]) -> [AttachmentSource] {
    return providers.compactMap { provider in
        guard let type = clipboardFileType(provider.registeredTypeIdentifiers) else { return nil }
        let suggested = provider.suggestedName.map { URL(fileURLWithPath: $0).lastPathComponent }
        let name = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? "Attachment.\(type.preferredFilenameExtension ?? "bin")"
        let mimeType = type == .fileURL ? UTType(filenameExtension: (name as NSString).pathExtension) : type
        return AttachmentSource(name: name, mime: mimeType?.preferredMIMEType ?? "application/octet-stream", load: {
            try await loadClipboardFile(provider, type: type)
        })
    }
}

/// NSItemProvider may return a temporary URL valid only inside the callback. Read there.
/// The finite deadline cancels provider work; a late callback cannot stage another attachment.
@MainActor private func loadClipboardFile(_ provider: NSItemProvider, type: UTType) async throws -> Data? {
    let read = ClipboardRead()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            read.start(continuation)
            if type == .fileURL {
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                    do {
                        let url: URL?
                        if let value = item as? URL { url = value }
                        else if let bytes = item as? Data, let string = String(data: bytes, encoding: .utf8) { url = URL(string: string) }
                        else if let string = item as? String { url = URL(string: string) }
                        else { url = nil }
                        guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                        read.finish(.success(try readAttachmentFile(url)))
                    } catch { read.finish(.failure(error)) }
                }
            } else {
                let progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    do {
                        guard let url else {
                            let fallback = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { bytes, failure in
                                guard let bytes, bytes.count <= AttachmentAcquisition.maxSourceBytes else {
                                    read.finish(.failure(failure ?? CocoaError(.fileReadTooLarge)))
                                    return
                                }
                                read.finish(.success(bytes))
                            }
                            read.setProgress(fallback)
                            return
                        }
                        read.finish(.success(try readAttachmentFile(url)))
                    } catch { read.finish(.failure(error)) }
                }
                read.setProgress(progress)
            }
        }
    } onCancel: { read.finish(.failure(CancellationError())) }
}

/// Protect callback/cancellation/deadline races with one continuation owner.
private final class ClipboardRead: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?
    private var outcome: Result<Data?, Error>?
    private var progress: Progress?
    private var timer: DispatchWorkItem?

    func start(_ continuation: CheckedContinuation<Data?, Error>) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(with: outcome); return }
        self.continuation = continuation
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(CocoaError(.fileReadUnknown))) }
        self.timer = timer
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
    }
    func setProgress(_ progress: Progress) {
        lock.lock()
        let finished = outcome != nil
        if !finished { self.progress = progress }
        lock.unlock()
        if finished { progress.cancel() }
    }
    func finish(_ result: Result<Data?, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = continuation
        self.continuation = nil
        let progress = progress
        self.progress = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
        progress?.cancel()
        continuation?.resume(with: result)
    }
}
#endif
