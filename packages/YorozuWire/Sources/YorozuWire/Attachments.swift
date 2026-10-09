import CryptoKit
import Foundation

// Attachments in 0.7, capability `attachments-v1` (docs/ios-relay-contract.md, "Attachments"). Files never ride in
// sync: records carry `AttachmentDescriptor`s, uploads go as `attachment_chunk`s plus one `attachment_commit`, and
// downloads as `attachment_download_request` / `attachment_download_chunk` pairs, one chunk per request.

/// A file stored with a message or a worker event (Mac -> phone, with `id`), or one the phone is about to commit
/// (phone -> Mac, `id` absent). `bytes` and `sha256` (lowercase hex) are of the whole file.
public struct AttachmentDescriptor: Codable, Equatable, Hashable, Sendable {
    /// The peer-info capability that says a side speaks attachments.
    public static let capability = "attachments-v1"
    /// sha256 of zero bytes: an empty file needs no chunks.
    public static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// The Mac's attachment id; absent in a commit.
    public var id: String?
    public var name: String
    public var mime: String
    public var bytes: Int
    public var sha256: String

    public init(id: String? = nil, name: String, mime: String, bytes: Int, sha256: String) {
        self.id = id
        self.name = name
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
    }

    public var isImage: Bool { mime.hasPrefix("image/") }

    /// Bounds both ends check: a name of 1–255 UTF-8 bytes and a type of 1–128 without control characters,
    /// 0…``MessageAttachment/maxBytes`` bytes, and a lowercase hex sha256 (the empty one for an empty file).
    public var isValid: Bool {
        func text(_ s: String, _ max: Int) -> Bool { !s.isEmpty && s.utf8.count <= max && !s.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
        return text(name, 255) && text(mime, 128) && (0...MessageAttachment.maxBytes).contains(bytes) && Self.isHash(sha256)
            && (bytes > 0 || sha256 == Self.emptySHA256) && (id.map(Self.isID) ?? true)
    }

    /// `^[A-Za-z0-9-]{1,64}$`, the shape of message and attachment ids on the wire.
    public static func isID(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9-]{1,64}\z"#, options: .regularExpression) != nil }
    public static func isHash(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    /// A file's descriptor for a commit, hashing it in 1 MiB reads.
    public static func make(file: URL, name: String, mime: String) throws -> AttachmentDescriptor {
        let (bytes, sha256) = try digest(of: file)
        return AttachmentDescriptor(name: name, mime: mime, bytes: bytes, sha256: sha256)
    }

    /// Size and lowercase hex sha256 of a file, read in 1 MiB pieces.
    public static func digest(of file: URL) throws -> (bytes: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256(), bytes = 0
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { hash.update(data: piece); bytes += piece.count }
        return (bytes, hex(hash.finalize()))
    }

    public static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

/// Error reasons in `attachment_progress` and `attachment_download_chunk`. Transient ones mean "try again later";
/// any other reason in a progress reply ends that upload (the phone shows Not delivered with Resend).
public enum AttachmentReason {
    public static let invalid = "invalid-attachment-chunk"
    public static let expired = "attachment-expired"
    public static let corrupt = "attachment-corrupt"
    public static let storageFull = "attachment-storage-full"
    public static let storageFailed = "attachment-storage-failed"
    public static let unavailable = "attachment-unavailable"
    public static let thumbnailUnavailable = "thumbnail-unavailable"
    public static let unsupported = "attachments-unsupported"
    public static let transient: Set<String> = [storageFull, storageFailed]
}

/// `attachment_chunk` (phone -> Mac): bytes `offset..<offset+n` of file `index` of message `messageId`, base64 in
/// `data`, at most ``MessageAttachment/chunkBytes`` decoded. Empty `data` asks only for the staged size. `deadline` is the
/// message's `admissionDeadline`. Answered by `attachment_progress` with `requestId` = this event's id.
public struct AttachmentChunkData: Codable, Equatable, Sendable {
    public var messageId: String
    public var index: Int
    public var offset: Int
    public var totalBytes: Int
    public var sha256: String
    public var deadline: Int
    public var data: String

    public init(messageId: String, index: Int, offset: Int, totalBytes: Int, sha256: String,
                deadline: Int, data: String) {
        self.messageId = messageId
        self.index = index
        self.offset = offset
        self.totalBytes = totalBytes
        self.sha256 = sha256
        self.deadline = deadline
        self.data = data
    }
}

/// `attachment_progress` (Mac -> phone): file `index` is staged up to `nextOffset`; the phone continues from there.
/// Also the answer to a commit that found a file incomplete (`requestId` = the commit's id = the message id).
public struct AttachmentProgressData: Codable, Equatable, Sendable {
    public var requestId: String
    public var messageId: String
    public var index: Int
    public var nextOffset: Int
    public var reason: String?

    public init(requestId: String, messageId: String, index: Int, nextOffset: Int, reason: String? = nil) {
        self.requestId = requestId
        self.messageId = messageId
        self.index = index
        self.nextOffset = nextOffset
        self.reason = reason
    }
}

/// `attachment_commit` (phone -> Mac), event id = the message id: the text and the files, in order, as one unit.
/// Answered like a `message`: `receipt`, `admission_status`, or `attachment_progress` for a file still incomplete.
public struct AttachmentCommitData: Codable, Equatable, Sendable {
    public var delivery: MessageDelivery?
    public var channelModel: ChannelModelChoice?
    public var text: String
    public var attachments: [AttachmentDescriptor]
    public var admissionDeadline: Int

    public init(text: String, attachments: [AttachmentDescriptor], admissionDeadline: Int, delivery: MessageDelivery? = nil, channelModel: ChannelModelChoice? = nil) {
        self.delivery = delivery
        self.channelModel = channelModel
        self.text = text
        self.attachments = attachments
        self.admissionDeadline = admissionDeadline
    }
}

/// `attachment_download_request` (phone -> Mac): the next chunk of an attachment from `offset`, of the file itself or,
/// with `thumbnail`, of the Mac's small JPEG preview of it.
public struct AttachmentDownloadRequestData: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var offset: Int
    public var thumbnail: Bool?

    public init(attachmentId: String, offset: Int, thumbnail: Bool? = nil) {
        self.attachmentId = attachmentId
        self.offset = offset
        self.thumbnail = thumbnail
    }
}

/// `attachment_download_chunk` (Mac -> phone): one answer per request, at most ``MessageAttachment/downloadChunkBytes``
/// decoded so the event is never split into `chunk`s. `totalBytes` and `sha256` describe what is being downloaded (the
/// thumbnail's own, for a thumbnail). On `reason` there is no data.
public struct AttachmentDownloadChunkData: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var thumbnail: Bool?
    public var offset: Int
    public var totalBytes: Int
    public var data: String
    public var sha256: String
    public var reason: String?

    public init(attachmentId: String, thumbnail: Bool? = nil, offset: Int, totalBytes: Int,
                data: String, sha256: String, reason: String? = nil) {
        self.attachmentId = attachmentId
        self.thumbnail = thumbnail
        self.offset = offset
        self.totalBytes = totalBytes
        self.data = data
        self.sha256 = sha256
        self.reason = reason
    }
}

/// v1's inline attachment, kept for its limits and for decoding; 0.7 sends descriptors, never inline bytes.
public struct MessageAttachment: Codable, Equatable, Sendable {
    /// Largest file, in bytes (50 MB, decimal, as Finder counts).
    public static let maxBytes = 50_000_000
    /// Upload chunk, decoded.
    public static let chunkBytes = 256 * 1024
    /// Download chunk, decoded: its base64 keeps the event under `ChunkData.budget`, so it is never split.
    public static let downloadChunkBytes = 160 * 1024
    public static let maxCount = 10
    /// No total beyond count × size (#316 open question 2).
    public static let maxTotalBytes = maxCount * maxBytes
    public static let maxPerMessage = maxCount
    public static let messageMaxBytes = maxTotalBytes

    public static func withinLimits(_ files: [AttachmentDescriptor]) -> Bool {
        files.count <= maxCount && files.allSatisfy { (0...maxBytes).contains($0.bytes) }
    }

    public var name: String
    public var mime: String
    /// The file itself, standard base64 with padding.
    public var data: String
    public var sizeBytes: Int?
    public var sha256: String?

    public init(name: String, mime: String, data: String, sizeBytes: Int? = nil, sha256: String? = nil) {
        self.name = name
        self.mime = mime
        self.data = data
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    public var isImage: Bool { mime.hasPrefix("image/") }
}

// MARK: Phone side

/// The phone's half of attachment transfers, over whichever route the session runs on (relay or direct). It sends
/// through `send` (`RelayClient.send`) and is fed every incoming event through ``handle(_:)``. It moves bytes only while
/// ``setLive(_:)`` says the Mac is reachable (`.paired`), so nothing lands in the relay's 5 MiB buffer.
///
/// Flow control: one upload chunk in flight at a time (about 460 KB on the wire, far under the relay buffer) and at most
/// two download requests in flight (each answered by one chunk of at most 160 KiB, so under 1 MiB of Mac -> phone
/// frames unacked). A request unanswered for 20 s is sent again; a new session (``setLive(_:)``) resends from the
/// offsets held.
///
/// The caller owns persistence: it saves each ``Update/uploadProgress(messageId:index:offset:)`` offset with its outbox
/// item and passes the saved offsets back in ``Upload`` after a relaunch. The Mac's `nextOffset` is authoritative either
/// way, so a stale offset only costs a round trip.
public actor AttachmentTransfers {
    public struct Upload: Codable, Equatable, Sendable {
        public struct File: Codable, Equatable, Sendable {
            /// A copy the phone keeps until the Mac has the message.
            public var url: URL
            /// From ``AttachmentDescriptor/make(file:name:mime:)``; `id` absent.
            public var descriptor: AttachmentDescriptor
            /// Bytes the Mac confirmed staged.
            public var offset: Int
            public init(url: URL, descriptor: AttachmentDescriptor, offset: Int = 0) {
                self.url = url
                self.descriptor = descriptor
                self.offset = offset
            }
        }
        /// The bubble's id; also the commit's event id and the stored message's id.
        public var messageId: String
        public var threadId: String
        /// The event `ts` (send time, epoch ms); Resend renews it with `admissionDeadline`.
        public var ts: Int
        public var text: String
        public var admissionDeadline: Int
        public var files: [File]
        public init(messageId: String, threadId: String = "main", ts: Int, text: String, admissionDeadline: Int, files: [File]) {
            self.messageId = messageId
            self.threadId = threadId
            self.ts = ts
            self.text = text
            self.admissionDeadline = admissionDeadline
            self.files = files
        }
    }

    public struct DownloadKey: Hashable, Sendable {
        public var attachmentId: String
        public var thumbnail: Bool
        public init(attachmentId: String, thumbnail: Bool) {
            self.attachmentId = attachmentId
            self.thumbnail = thumbnail
        }
    }

    public enum Update: Sendable, Equatable {
        /// The Mac has file `index` up to `offset`: persist it.
        case uploadProgress(messageId: String, index: Int, offset: Int)
        /// Every file is staged and the commit went out; the outcome is the usual `receipt` or `admission_status`.
        case uploadCommitted(messageId: String)
        /// The upload cannot go on (`AttachmentReason`, or a local file gone); show Not delivered.
        case uploadFailed(messageId: String, reason: String)
        case downloadProgress(DownloadKey, received: Int, total: Int)
        /// The verified file, moved to the destination given to ``download(_:expected:to:)``.
        case downloaded(DownloadKey, URL)
        /// `AttachmentReason.unavailable` means "File no longer available"; a partial file is kept only for a full
        /// download that was merely interrupted, never after a failure.
        case downloadFailed(DownloadKey, reason: String)
    }

    /// Phone-side reasons in `uploadFailed` / `downloadFailed`.
    public static let localFileMissing = "attachment-missing-locally"
    public static let integrityFailed = "attachment-integrity"

    public nonisolated let updates: AsyncStream<Update>
    private let out: AsyncStream<Update>.Continuation
    private let send: @Sendable (YorozuEvent) async throws -> Void

    private struct Download { var expected: AttachmentDescriptor?; var destination: URL; var received: Int; var total: Int?; var sha256: String? }
    private struct InFlight { var requestId: String; var index: Int; var at: ContinuousClock.Instant }
    private var live = false
    private var uploads: [Upload] = []
    /// The one upload frame in flight: index -1 is a commit.
    private var uploading: (messageId: String, flight: InFlight)?
    /// Uploads held back after a transient refusal, until then.
    private var holdUntil: ContinuousClock.Instant?
    private var downloads: [DownloadKey: Download] = [:]
    private var order: [DownloadKey] = []
    private var downloading: [DownloadKey: (offset: Int, at: ContinuousClock.Instant)] = [:]
    private var watchdog: Task<Void, Never>?
    private static let timeout = Duration.seconds(20), maxDownloads = 2

    public init(send: @escaping @Sendable (YorozuEvent) async throws -> Void) {
        self.send = send
        (updates, out) = AsyncStream<Update>.makeStream()
    }

    deinit { watchdog?.cancel(); out.finish() }

    /// True on `.paired`, false when the session drops. Each new session starts the frames in flight over.
    public func setLive(_ live: Bool) {
        self.live = live
        uploading = nil; downloading = [:]
        if live, watchdog == nil {
            watchdog = Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); await self?.tick() }
            }
        } else if !live { watchdog?.cancel(); watchdog = nil }
        pump()
    }

    /// Queues a message's files and commit, or replaces the queued one with the same `messageId` (Resend).
    public func upload(_ upload: Upload) {
        if let i = uploads.firstIndex(where: { $0.messageId == upload.messageId }) { uploads[i] = upload } else { uploads.append(upload) }
        if uploading?.messageId == upload.messageId { uploading = nil }
        pump()
    }

    public func cancelUpload(_ messageId: String) {
        uploads.removeAll { $0.messageId == messageId }
        if uploading?.messageId == messageId { uploading = nil }
        pump()
    }

    /// Streams an attachment (or its thumbnail) to `destination`, through `destination` + ".part". A full download
    /// resumes from an existing part; `expected` (the record's descriptor) is checked against what the Mac sends.
    public func download(_ key: DownloadKey, expected: AttachmentDescriptor? = nil, to destination: URL) {
        guard downloads[key] == nil else { return }
        let part = Self.part(destination)
        var received = 0
        if key.thumbnail { try? FileManager.default.removeItem(at: part) }
        else { received = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int) ?? 0 }
        if let bytes = expected?.bytes, received > bytes { try? FileManager.default.removeItem(at: part); received = 0 }
        downloads[key] = Download(expected: expected, destination: destination, received: received)
        order.append(key)
        pump()
    }

    /// Stops a download, keeping a full download's part for later.
    public func cancelDownload(_ key: DownloadKey) {
        downloads[key] = nil; order.removeAll { $0 == key }; downloading[key] = nil
        pump()
    }

    /// Feed every incoming event. Returns true for the attachment events it consumed. A `receipt` or `admission_status`
    /// also ends that message's upload, but returns false: the outbox still handles it.
    @discardableResult public func handle(_ event: YorozuEvent) -> Bool {
        switch event.payload {
        case .attachmentProgress(let p): progress(p); return true
        case .attachmentDownloadChunk(let c): chunk(c); return true
        case .receipt(let r): finish(r.eventId); return false
        case .admissionStatus(let a): finish(a.eventId); return false
        default: return false
        }
    }

    // MARK: Upload

    private func finish(_ messageId: String) {
        guard uploads.contains(where: { $0.messageId == messageId }) else { return }
        cancelUpload(messageId)
    }

    private func progress(_ p: AttachmentProgressData) {
        guard let flight = uploading, flight.messageId == p.messageId, flight.flight.requestId == p.requestId,
              let u = uploads.firstIndex(where: { $0.messageId == p.messageId }) else { return }
        uploading = nil
        if let reason = p.reason {
            if AttachmentReason.transient.contains(reason) { holdUntil = .now + .seconds(10); return }
            uploads.remove(at: u)
            out.yield(.uploadFailed(messageId: p.messageId, reason: reason))
            return pump()
        }
        guard uploads[u].files.indices.contains(p.index) else { return pump() }
        let offset = min(max(0, p.nextOffset), uploads[u].files[p.index].descriptor.bytes)
        uploads[u].files[p.index].offset = offset
        out.yield(.uploadProgress(messageId: p.messageId, index: p.index, offset: offset))
        pump()
    }

    private func pumpUpload() {
        guard uploading == nil, holdUntil.map({ $0 <= .now }) ?? true, let u = uploads.first else { return }
        holdUntil = nil
        let id = UUID().uuidString
        let event: YorozuEvent, index: Int
        if let i = u.files.firstIndex(where: { $0.offset < $0.descriptor.bytes }) {
            let f = u.files[i]
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: f.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(f.offset))
                data = try handle.read(upToCount: MessageAttachment.chunkBytes) ?? Data()
                guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                uploads.removeFirst()
                out.yield(.uploadFailed(messageId: u.messageId, reason: Self.localFileMissing))
                return pumpUpload()
            }
            index = i
            event = YorozuEvent(id: id, threadId: u.threadId, ts: Self.now, agentId: "device",
                                payload: .attachmentChunk(AttachmentChunkData(messageId: u.messageId, index: i, offset: f.offset,
                                    totalBytes: f.descriptor.bytes, sha256: f.descriptor.sha256, deadline: u.admissionDeadline,
                                    data: data.base64EncodedString())))
        } else {
            index = -1
            event = YorozuEvent(id: u.messageId, threadId: u.threadId, ts: u.ts, agentId: "device",
                                payload: .attachmentCommit(AttachmentCommitData(text: u.text, attachments: u.files.map(\.descriptor),
                                                                                admissionDeadline: u.admissionDeadline)))
        }
        let requestId = index < 0 ? u.messageId : id
        uploading = (u.messageId, InFlight(requestId: requestId, index: index, at: .now))
        let send = self.send
        Task {
            do {
                try await send(event)
                if index < 0 { self.yield(.uploadCommitted(messageId: u.messageId)) }
            } catch { self.sendFailed(messageId: u.messageId, requestId: requestId) }
        }
    }

    private func yield(_ update: Update) { out.yield(update) }

    /// A frame that could not be sent is retried on the next tick, not at once.
    private func sendFailed(messageId: String, requestId: String) {
        if uploading?.messageId == messageId, uploading?.flight.requestId == requestId { uploading?.flight.at = .now - Self.timeout }
    }

    // MARK: Download

    private func chunk(_ c: AttachmentDownloadChunkData) {
        let key = DownloadKey(attachmentId: c.attachmentId, thumbnail: c.thumbnail ?? false)
        guard var d = downloads[key], downloading[key]?.offset == c.offset else { return }
        downloading[key] = nil
        let part = Self.part(d.destination)
        func fail(_ reason: String) {
            try? FileManager.default.removeItem(at: part)
            downloads[key] = nil; order.removeAll { $0 == key }
            out.yield(.downloadFailed(key, reason: reason))
            pump()
        }
        if let reason = c.reason { return fail(reason) }
        guard let bytes = Data(base64Encoded: c.data), bytes.count <= MessageAttachment.downloadChunkBytes, c.offset == d.received,
              c.totalBytes >= 0, c.offset + bytes.count <= c.totalBytes, AttachmentDescriptor.isHash(c.sha256),
              d.total.map({ $0 == c.totalBytes }) ?? true, d.sha256.map({ $0 == c.sha256 }) ?? true,
              key.thumbnail || d.expected.map({ $0.bytes == c.totalBytes && $0.sha256 == c.sha256 }) ?? true,
              !bytes.isEmpty || c.offset == c.totalBytes else { return fail(Self.integrityFailed) }
        d.total = c.totalBytes; d.sha256 = c.sha256
        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: part.path) {
                try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(c.offset))
            try handle.write(contentsOf: bytes)
        } catch { return fail(AttachmentReason.storageFailed) }
        d.received += bytes.count
        downloads[key] = d
        out.yield(.downloadProgress(key, received: d.received, total: c.totalBytes))
        if d.received == c.totalBytes {
            guard (try? AttachmentDescriptor.digest(of: part))?.sha256 == c.sha256 else { return fail(Self.integrityFailed) }
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: d.destination.path) { try fm.removeItem(at: d.destination) }
                try fm.moveItem(at: part, to: d.destination)
            } catch { return fail(AttachmentReason.storageFailed) }
            downloads[key] = nil; order.removeAll { $0 == key }
            out.yield(.downloaded(key, d.destination))
        }
        pump()
    }

    private func pumpDownloads() {
        for key in order where downloading.count < Self.maxDownloads && downloading[key] == nil {
            guard let d = downloads[key] else { continue }
            downloading[key] = (d.received, .now)
            let event = YorozuEvent(id: UUID().uuidString, threadId: "", ts: Self.now, agentId: "device",
                                    payload: .attachmentDownloadRequest(AttachmentDownloadRequestData(attachmentId: key.attachmentId, offset: d.received,
                                                                                                      thumbnail: key.thumbnail ? true : nil)))
            let send = self.send
            Task { do { try await send(event) } catch { self.downloadSendFailed(key) } }
        }
    }

    private func downloadSendFailed(_ key: DownloadKey) { if downloading[key] != nil { downloading[key]?.at = .now - Self.timeout } }

    // MARK: Pump

    private func pump() {
        guard live else { return }
        pumpUpload()
        pumpDownloads()
    }

    /// Requests unanswered for 20 s go again.
    private func tick() {
        let now = ContinuousClock.now
        if let at = uploading?.flight.at, at.duration(to: now) >= Self.timeout { uploading = nil }
        for (key, flight) in downloading where flight.at.duration(to: now) >= Self.timeout { downloading[key] = nil }
        pump()
    }

    private static func part(_ destination: URL) -> URL { destination.appendingPathExtension("part") }
    private static var now: Int { Int(Date().timeIntervalSince1970 * 1000) }
}
