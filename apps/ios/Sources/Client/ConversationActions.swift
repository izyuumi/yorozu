import Foundation

enum ConversationRowAction: Equatable, Hashable {
    case archive, unarchive, delete
}

/// What a chat's row offers, by whether the chat is archived (`archived == true`); Delete is for archived chats only.
enum ConversationActions {
    /// Trailing swipe buttons in order; the first one is the full-swipe action.
    static func trailingSwipe(archived: Bool) -> [ConversationRowAction] {
        archived ? [.delete, .unarchive] : [.archive]
    }

    /// The archive and delete items of the context menu, in order.
    static func menu(archived: Bool) -> [ConversationRowAction] {
        archived ? [.unarchive, .delete] : [.archive]
    }

    /// After a confirmed Delete: clear selection only when that delete was accepted for the selected chat.
    static func selectionAfterConfirmedDelete(selection: String?, deletedId: String, succeeded: Bool) -> String? {
        if succeeded, selection == deletedId { return nil }
        return selection
    }
}
