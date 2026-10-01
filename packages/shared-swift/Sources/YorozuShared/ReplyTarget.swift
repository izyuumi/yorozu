import Foundation

/// A bounded, encrypted composer preview. Only the stable message ID goes to the host;
/// the host resolves the actual quoted context from its own conversation history.
public struct ReplyTarget: Codable, Equatable, Sendable {
    public let eventId: String
    public let role: MessageData.Role
    public let preview: String

    init(eventId: String, message: MessageData) {
        self.eventId = eventId
        self.role = message.role
        let source = message.text.isEmpty ? message.attachments.map(\.name).joined(separator: ", ") : message.text
        // Bound bytes before grapheme counting: one character can contain many combining marks.
        self.preview = String(String(decoding: source.utf8.prefix(2000), as: UTF8.self).prefix(500))
    }
}
