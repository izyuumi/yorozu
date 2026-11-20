import Foundation

enum ConversationRowAction: Equatable, Hashable {
    case archive, unarchive, delete
}

enum ConversationActions {
    static func trailingSwipe(archived: Bool) -> [ConversationRowAction] {
        archived ? [.delete, .unarchive] : [.archive]
    }

    static func menu(archived: Bool) -> [ConversationRowAction] {
        archived ? [.unarchive, .delete] : [.archive]
    }

    static func selectionAfterConfirmedDelete(selection: String?, deletedId: String, succeeded: Bool) -> String? {
        if succeeded, selection == deletedId { return nil }
        return selection
    }
}
