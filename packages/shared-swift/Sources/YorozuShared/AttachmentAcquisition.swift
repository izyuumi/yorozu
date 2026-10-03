import Foundation

/// A retry retains only failed sources; successful files are never loaded or attached twice.
@MainActor
struct AttachmentSource {
    let name: String
    let mime: String
    let load: @MainActor () async throws -> Data?
}

@MainActor
struct AttachmentLoadResult {
    var picks: [(name: String, mime: String, bytes: Data)] = []
    var failed: [AttachmentSource] = []
}

@MainActor
enum AttachmentAcquisition {
    static func load(_ sources: [AttachmentSource]) async throws -> AttachmentLoadResult {
        var result = AttachmentLoadResult()
        for source in sources {
            try Task.checkCancellation()
            do {
                let bytes = try await source.load()
                try Task.checkCancellation()
                if let bytes {
                    result.picks.append((source.name, source.mime, bytes))
                } else {
                    result.failed.append(source)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                result.failed.append(source)
            }
        }
        return result
    }
}

struct AttachmentDraftResult {
    let attachments: [MessageAttachment]
    let rejectedCount: Int
}

/// Preserve the draft and every incoming file that fits, even when another item is refused.
func addingAttachments(_ picked: [MessageAttachment], to existing: [MessageAttachment]) -> AttachmentDraftResult {
    var attachments = existing
    var totalBytes = existing.reduce(0) { $0 + $1.byteCount }
    var rejectedCount = 0
    for attachment in picked {
        guard attachments.count < MessageAttachment.maxCount,
            let bytes = attachment.bytes,
            bytes.count <= MessageAttachment.maxBytes,
            totalBytes + bytes.count <= MessageAttachment.maxTotalBytes
        else {
            rejectedCount += 1
            continue
        }
        attachments.append(attachment)
        totalBytes += bytes.count
    }
    return AttachmentDraftResult(attachments: attachments, rejectedCount: rejectedCount)
}
