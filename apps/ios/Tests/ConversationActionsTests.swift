import Testing

@Suite struct ConversationActionsTests {
    @Test func anActiveChatSwipesToArchiveOnly() {
        #expect(ConversationActions.trailingSwipe(archived: false) == [.archive])
    }

    @Test func anArchivedChatSwipesToDeleteThenUnarchive() {
        #expect(ConversationActions.trailingSwipe(archived: true) == [.delete, .unarchive])
    }

    @Test func anActiveChatsMenuHasArchiveAndNoDelete() {
        #expect(ConversationActions.menu(archived: false) == [.archive])
    }

    @Test func anArchivedChatsMenuHasUnarchiveThenDelete() {
        #expect(ConversationActions.menu(archived: true) == [.unarchive, .delete])
    }

    @Test func aRefusedDeleteKeepsTheSelection() {
        #expect(ConversationActions.selectionAfterConfirmedDelete(selection: "a", deletedId: "a", succeeded: false) == "a")
        #expect(ConversationActions.selectionAfterConfirmedDelete(selection: "b", deletedId: "a", succeeded: false) == "b")
        #expect(ConversationActions.selectionAfterConfirmedDelete(selection: nil, deletedId: "a", succeeded: false) == nil)
    }

    @Test func anAcceptedDeleteOfTheSelectedChatClearsTheSelection() {
        #expect(ConversationActions.selectionAfterConfirmedDelete(selection: "a", deletedId: "a", succeeded: true) == nil)
    }

    @Test func anAcceptedDeleteOfAnotherChatKeepsTheSelection() {
        #expect(ConversationActions.selectionAfterConfirmedDelete(selection: "b", deletedId: "a", succeeded: true) == "b")
    }
}
