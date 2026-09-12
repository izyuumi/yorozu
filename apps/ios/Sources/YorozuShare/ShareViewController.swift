import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YorozuShared

/// The share sheet's entry point. It reads what was shared, shows the composer, and writes the
/// result into the App Group container — that is the whole of it.
///
/// It deliberately holds no relay client, no pairing and no Keychain access group. The app owns
/// the socket and the outbox; an extension that opened a second socket would be a second device
/// in the room for as long as the sheet was up, and would have to be given the pairing's private
/// keys to do it. Writing a file and stepping aside costs one hop and none of that.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // The sheet is presented over the host app, which should show through around it.
        view.backgroundColor = .clear

        let host = UIHostingController(
            rootView: ShareComposeView(
                threads: ShareBox.directory().map { ShareBox.threads(in: $0) } ?? [],
                load: { [weak self] in await self?.sharedItem() ?? .unsupported },
                send: { [weak self] in self?.hand(over: $0) },
                cancel: { [weak self] in self?.dismiss(cancelled: true) }
            )
        )
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Writes the share where the app will find it and asks iOS to open the app on it.
    ///
    /// The write is what matters and the URL is not: `open` is refused to some extensions and
    /// silently dropped by others, so the app also drains this directory every time it comes to
    /// the foreground. Worst case the share is sent when Yorozu is next opened rather than now.
    private func hand(over payload: SharePayload) {
        guard let directory = ShareBox.directory(),
            let token = try? ShareBox.write(payload, in: directory),
            let url = URL(string: "yorozu://share?token=\(token)")
        else { return dismiss(cancelled: false) }
        extensionContext?.open(url)
        dismiss(cancelled: false)
    }

    private func dismiss(cancelled: Bool) {
        guard cancelled else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        extensionContext?.cancelRequest(
            withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
    }

    /// The first thing in the share that this extension knows how to carry. A share is usually
    /// one item with several representations of it — a web page arrives as a URL *and* as its
    /// title as plain text — so the first match in preference order is the whole answer rather
    /// than something to keep collecting after.
    private func sharedItem() async -> SharedItem {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        for type in [UTType.url, .plainText, .image] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let item = await SharedItem(provider: provider, type: type) { return item }
            }
        }
        return .unsupported
    }
}
