#if os(iOS)
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    /// What was shared, reduced to what the composer draws and what the app sends.
    ///
    /// Deliberately not called `none` for the empty case: this is held in an `Optional` while it
    /// loads, and `case .none` in a switch over that would mean the Optional's.
    public enum SharedItem {
        case unsupported
        case text(String)
        case link(URL)
        case image(UIImage, MessageAttachment)
        /// A picture too big to send. A case of its own so the composer can say so instead of
        /// offering a Send that would quietly drop it.
        case tooLarge(UIImage)

        public init?(provider: NSItemProvider, type: UTType) async {
            switch type {
            case .url:
                guard let url = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? URL
                else { return nil }
                // A shared *file* also arrives as a URL. Only a web link is one this can carry as
                // text; a file URL means nothing on the other side of the relay.
                guard !url.isFileURL else { return nil }
                self = .link(url)
            case .plainText:
                guard
                    let text = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? String,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                self = .text(text)
            default:
                guard let image = await Self.image(from: provider, type: type) else { return nil }
                // JPEG rather than the original: a modern phone photo is well over the cap as
                // HEIC and far over it as PNG, and the message is sealed and held whole in memory
                // at both ends. 0.8 is the usual place where a re-encode stops being visible.
                guard let data = image.jpegData(compressionQuality: 0.8),
                    let attachment = MessageAttachment(name: "Shared.jpg", mime: "image/jpeg", bytes: data)
                else {
                    self = .tooLarge(image)
                    return
                }
                self = .image(image, attachment)
            }
        }

        private static func image(from provider: NSItemProvider, type: UTType) async -> UIImage? {
            if let image = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? UIImage {
                return image
            }
            // The common case: an image arrives as a URL into the sender's container, or as raw
            // bytes.
            if let url = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? URL,
                let data = try? Data(contentsOf: url)
            {
                return UIImage(data: data)
            }
            guard let data = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? Data
            else { return nil }
            return UIImage(data: data)
        }

        /// The text the message carries for this item, under whatever note was typed.
        public var messageText: String {
            switch self {
            case .text(let text): text
            case .link(let url): url.absoluteString
            case .unsupported, .image, .tooLarge: ""
            }
        }

        public var attachment: MessageAttachment? {
            if case .image(_, let attachment) = self { return attachment }
            return nil
        }
    }

    /// The composer the share sheet puts up. It asks three questions in the order they are
    /// actually answered — is this the right thing, is there anything to say about it, and where
    /// does it go — and nothing else. A new session always requires an explicit host choice.
    ///
    /// It lives in the shared package rather than in the extension so the app can put it on
    /// screen too: nothing on a simulator can open a share sheet on demand, and a screenshot of
    /// this is worth having.
    public struct ShareComposeView: View {
        let hosts: [ShareHost]
        let threads: [ShareThread]
        let load: () async -> SharedItem
        let send: (SharePayload) -> Void
        let cancel: () -> Void

        public init(
            hosts: [ShareHost] = [],
            threads: [ShareThread],
            load: @escaping () async -> SharedItem,
            send: @escaping (SharePayload) -> Void,
            cancel: @escaping () -> Void
        ) {
            self.hosts = hosts
            self.threads = threads
            self.load = load
            self.send = send
            self.cancel = cancel
        }

        @State private var item: SharedItem?
        @State private var note = ""
        /// Nil is "New session", which is also where a first-time share goes: offering the newest
        /// thread by default would put a link in whatever was last talked about, which is rarely
        /// where it belongs.
        @State private var destination: HostThreadID?
        @State private var newHostID: HostID?
        @FocusState private var noteFocused: Bool

        public var body: some View {
            NavigationStack {
                Form {
                    Section {
                        if let item {
                            SharedItemPreview(item: item)
                                // The preview is the subject of the sheet, not a row to tap.
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        } else {
                            // Rare and brief — reading a photo out of another app's container —
                            // but a blank sheet with a live Send button would be worse than a line.
                            Label("Reading what you shared…", systemImage: "ellipsis")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        TextField("Add a note", text: $note, axis: .vertical)
                            .lineLimit(1...5)
                            .focused($noteFocused)
                    } footer: {
                        if case .tooLarge? = item {
                            Text(
                                "That picture is over \(MessageAttachment.maxBytes / 1_048_576) MB. Send it from the app instead."
                            )
                            .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        ShareThreadRow(
                            title: String(localized: "New session"),
                            symbol: "plus.bubble",
                            selected: destination == nil
                        ) {
                            destination = nil
                            newHostID = nil
                        }
                        if destination == nil {
                            Picker("Host", selection: $newHostID) {
                                Text("Choose a host").tag(nil as HostID?)
                                ForEach(hosts) { host in
                                    Text(host.label).tag(Optional(host.id))
                                }
                            }
                            .accessibilityIdentifier("share-host-picker")
                        }
                        ForEach(availableThreads.prefix(5), id: \.destination) { thread in
                            ShareThreadRow(
                                title: thread.title,
                                subtitle: thread.hostLabel ?? hosts.first { $0.id == thread.hostID }?.label,
                                symbol: "bubble.left.and.bubble.right",
                                selected: destination == thread.destination
                            ) {
                                destination = thread.destination
                            }
                        }
                    } header: {
                        Text("Send to")
                    } footer: {
                        if hosts.isEmpty {
                            Text("Open Yorozu to connect a host before sharing.")
                        } else {
                            Text("Choose the Mac that should receive this. If it is offline, this waits securely until it reconnects.")
                        }
                    }
                }
                .navigationTitle("Yorozu")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send", action: hand)
                            .fontWeight(.semibold)
                            .disabled(!canSend)
                    }
                }
            }
            .task {
                item = await load()
                // The note is the only thing left to type, so the keyboard comes up on it — but
                // only once there is something above it to be a note *about*. Not while being
                // screenshotted: there the keyboard would cover the picker below.
                noteFocused = !ChatShowcase.share
            }
        }

        private var availableThreads: [ShareThread] {
            threads.filter { thread in
                guard let hostID = thread.hostID else { return false }
                return hosts.contains { $0.id == hostID }
            }
        }

        private var selectedHostID: HostID? {
            let hostID = destination?.hostID ?? newHostID
            return hostID.flatMap { id in hosts.contains { $0.id == id } ? id : nil }
        }

        /// A note on its own is a message; a shared thing on its own is a message. Only both
        /// empty, or a picture that cannot go, is nothing to send.
        private var canSend: Bool {
            guard selectedHostID != nil, let item else { return false }
            if case .tooLarge = item { return false }
            return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !item.messageText.isEmpty
                || item.attachment != nil
        }

        /// The note first and the shared thing under it, which is the order they were meant in:
        /// the note is what you are saying, the link is what you are saying it about.
        private func hand() {
            guard canSend, let hostID = selectedHostID, let item else { return }
            let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = [note, item.messageText].filter { !$0.isEmpty }.joined(separator: "\n\n")
            send(SharePayload(hostID: hostID, threadId: destination?.threadID, text: text, attachment: item.attachment))
        }
    }

    /// What was shared, drawn as itself: a link as a link, a quotation as a quotation, a picture
    /// as the picture. Never as a file name.
    private struct SharedItemPreview: View {
        let item: SharedItem

        var body: some View {
            switch item {
            case .link(let url):
                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        // The host is what identifies a link at a glance; the path is the detail
                        // under it, and is the part worth truncating.
                        Text(url.host() ?? url.absoluteString)
                            .font(.headline)
                            .lineLimit(1)
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            case .text(let text):
                HStack(alignment: .top, spacing: 12) {
                    // A quotation rule rather than quote marks: it survives text that has its own.
                    Capsule()
                        .fill(.tint)
                        .frame(width: 3)
                    Text(text)
                        .font(.callout)
                        .lineLimit(6)
                }
                .fixedSize(horizontal: false, vertical: true)
            case .image(let image, let attachment):
                HStack(spacing: 12) {
                    Thumbnail(image: image)
                    Text(size(of: attachment))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .tooLarge(let image):
                HStack(spacing: 12) {
                    Thumbnail(image: image).opacity(0.4)
                    Text("Too large to send")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .unsupported:
                Text("Nothing Yorozu can send.")
                    .foregroundStyle(.secondary)
            }
        }

        private func size(of attachment: MessageAttachment) -> String {
            (attachment.bytes?.count).map {
                ByteCountFormatStyle(style: .file).format(Int64($0))
            } ?? "Picture"
        }
    }

    /// The shared picture at a size that says which picture it is without taking over the sheet.
    private struct Thumbnail: View {
        let image: UIImage

        var body: some View {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// One destination. A checkmark rather than a radio button: this is a list of threads with
    /// one of them chosen, which is what a checkmark means everywhere else on the phone.
    private struct ShareThreadRow: View {
        let title: String
        var subtitle: String? = nil
        let symbol: String
        let selected: Bool
        let choose: () -> Void

        var body: some View {
            Button(action: choose) {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).lineLimit(1)
                            if let subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } icon: {
                        Image(systemName: symbol)
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }
            .tint(.primary)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }
#endif
