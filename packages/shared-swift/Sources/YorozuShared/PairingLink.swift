import Foundation
import SwiftUI

// What a tapped `yorozu://` link is allowed to do, shared by both apps so the phone and a
// client Mac ask the same question in the same words before a link replaces their pairing.

extension QrPayload {
    /// The relay the code points at, as the consent prompt names it. Nil when the relay is not
    /// a URL at all, which ``QrPayload/decode(_:)`` refuses anyway.
    public var relayHost: String? { URLComponents(string: relayUrl)?.host }

    /// The Mac X25519 key this code carries, shortened to something a person can compare
    /// against the Mac's Devices screen: the first 8 bytes as hex, one byte per group.
    public var macKeyFingerprint: String? { Self.fingerprint(ofBase64URLKey: macPubkey) }

    /// A short, human-comparable fingerprint of a base64url key: its first 8 bytes as hex,
    /// grouped in pairs. Nil for anything that does not decode to at least 8 bytes.
    public static func fingerprint(ofBase64URLKey key: String) -> String? {
        guard let bytes = Data(base64URLEncoded: key), bytes.count >= 8 else { return nil }
        return bytes.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// What the chat timeline does with a link somebody tapped in a message.
public enum ChatLinkDecision: Equatable, Sendable {
    /// Hand it to the system: a web page or a mail address.
    case open
    /// A `yorozu://pair` code, which goes to the app's pairing consent rather than to the
    /// system — the system would hand it straight back through `onOpenURL`.
    case pairing
    /// Anything else. A model's reply is untrusted text, and `tel:`, `file:`, `sms:` or a
    /// custom scheme opened from it is a tap nobody meant.
    case discard
}

/// The one rule for links in messages. Pure, so it is tested as a table.
public enum ChatLinkPolicy {
    public static func decision(for url: URL) -> ChatLinkDecision {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host() == nil ? .discard : .open
        case "mailto":
            return .open
        case "yorozu":
            return url.host()?.lowercased() == "pair" ? .pairing : .discard
        default:
            return .discard
        }
    }
}

extension OpenURLAction {
    /// The timeline's link handling as one action: ``ChatLinkPolicy`` decides, and a pairing
    /// code goes to `onPairingLink`, which is where the app asks before replacing anything.
    public static func chatLinks(onPairingLink: ((URL) -> Void)?) -> OpenURLAction {
        OpenURLAction { url in
            switch ChatLinkPolicy.decision(for: url) {
            case .open: return .systemAction
            case .pairing:
                // Nowhere to ask — a preview, the showcase — and the code is dropped like the rest.
                guard let onPairingLink else { return .discarded }
                onPairingLink(url)
                return .handled
            case .discard: return .discarded
            }
        }
    }
}

extension EnvironmentValues {
    /// Where a `yorozu://pair` link tapped in a chat goes. Set by each app to the same consent
    /// path its `onOpenURL` uses; nil drops the link, so a chat rendered somewhere without a
    /// pairing lifecycle — the showcase, a preview — cannot pair anything. Optional, the shape
    /// ``fetchToolResult`` has: absent is a state the row can read, not a closure that does nothing.
    @Entry public var onPairingLink: ((URL) -> Void)? = nil
}
