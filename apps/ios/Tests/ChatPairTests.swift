import Testing

/// HomeView's side of the pair: it owns `selection`, and every change to it reaches `selectionChanged`, including
/// the ones the pair itself makes.
private struct Home {
    var pair = ChatPair()
    var selection: String?

    init(_ selection: String?) { self.selection = selection }

    mutating func run(compact: Bool = false, _ change: (inout ChatPair, inout String?) -> Void) {
        var old = selection
        change(&pair, &selection)
        while old != selection {
            let new = selection
            pair.selectionChanged(from: old, to: new, compact: compact, selection: &selection)
            old = new
        }
        #expect(pair.partner == nil || pair.partner != selection)
    }

    mutating func select(_ convId: String?, compact: Bool = false) { run(compact: compact) { _, selection in selection = convId } }

    /// X on the left, Y focused on the right, reached through the picker.
    static func split() -> Home {
        var home = Home("X")
        home.pair.choosing = true
        home.select("Y")
        return home
    }
}

@Suite struct ChatPairTests {
    @Test func startingThePickerDoesNotReplaceAnOpenSplit() {
        var home = Home.split()
        home.pair.choosing = true
        #expect(home.pair.partner == "X")
        #expect(home.pair.isOpen)
        #expect(!home.pair.choosing)
    }

    @Test func deletingThePickersConversationClosesThePicker() {
        var home = Home("X")
        home.pair.choosing = true
        home.select(nil)
        #expect(!home.pair.choosing)
        #expect(!home.pair.isOpen)
        home.select("blank")
        #expect(!home.pair.isOpen)
        #expect(home.pair.partner == nil)
    }

    @Test func aSelectionFromNoneClosesThePicker() {
        var home = Home(nil)
        home.pair.choosing = true
        home.select("Y")
        #expect(!home.pair.choosing)
        #expect(!home.pair.isOpen)
        #expect(home.pair.partner == nil)
        #expect(home.selection == "Y")
    }

    @Test func pickingInTheSidebarSplitsWithThePickersConversationOnTheLeft() {
        let home = Home.split()
        #expect(!home.pair.choosing)
        #expect(home.pair.partner == "X")
        #expect(home.pair.partnerOnLeft)
        #expect(home.pair.focusedSide == .right)
        #expect(home.selection == "Y")
        #expect(home.pair.side(of: "X", selection: home.selection) == .left)
        #expect(home.pair.side(of: "Y", selection: home.selection) == .right)
        #expect(home.pair.side(of: "Z", selection: home.selection) == nil)
    }

    @Test func pickingInThePickerSplitsWithThePickersConversationOnTheLeft() {
        var home = Home("X")
        home.pair.choosing = true
        home.run { pair, selection in pair.openBeside("Y", selection: &selection) }
        #expect(!home.pair.choosing)
        #expect(home.pair.partner == "X")
        #expect(home.pair.focusedSide == .right)
        #expect(home.selection == "Y")
    }

    @Test func cancellingThePickerKeepsTheConversation() {
        var home = Home("X")
        home.pair.choosing = true
        home.run { pair, selection in pair.close(.right, selection: &selection) }
        #expect(!home.pair.isOpen)
        #expect(home.selection == "X")
    }

    @Test func selectingThePartnerFocusesItsSide() {
        var home = Home.split()
        home.select("X")
        #expect(home.selection == "X")
        #expect(home.pair.partner == "Y")
        #expect(home.pair.focusedSide == .left)
        #expect(home.pair.side(of: "Y", selection: home.selection) == .right)
    }

    @Test func closingTheFocusedSideFocusesThePartner() {
        var home = Home.split()
        home.run { pair, selection in pair.close(.right, selection: &selection) }
        #expect(!home.pair.isOpen)
        #expect(home.selection == "X")
    }

    @Test func closingThePartnersSideKeepsTheFocus() {
        var home = Home.split()
        home.run { pair, selection in pair.close(.left, selection: &selection) }
        #expect(!home.pair.isOpen)
        #expect(home.selection == "Y")
    }

    @Test func droppingOnTheRightOpensItThere() {
        var home = Home("X")
        home.run { pair, selection in pair.drop("Y", on: .right, selection: &selection) }
        #expect(home.selection == "Y")
        #expect(home.pair.partner == "X")
        #expect(home.pair.focusedSide == .right)
    }

    @Test func clearingTheSelectionPromotesThePartner() {
        var home = Home.split()
        home.select(nil)
        #expect(!home.pair.isOpen)
        #expect(home.selection == "X")
    }

    @Test func compactKeepsThePartner() {
        var home = Home.split()
        home.select(nil, compact: true)
        #expect(home.pair.partner == "X")
        #expect(home.selection == nil)
    }

    @Test func showingThePartnerFocusesIt() {
        var home = Home.split()
        home.run { pair, selection in pair.show("X", on: .right, selection: &selection) }
        #expect(home.selection == "X")
        #expect(home.pair.partner == "Y")
        #expect(home.pair.focusedSide == .left)
    }

    @Test func showingOnTheFocusedSideReplacesIt() {
        var home = Home.split()
        home.run { pair, selection in pair.show("Z", on: .right, selection: &selection) }
        #expect(home.selection == "Z")
        #expect(home.pair.partner == "X")
        #expect(home.pair.focusedSide == .right)
    }

    @Test func openingTheFocusedConversationBesideItselfKeepsOnePane() {
        var home = Home("X")
        home.run { pair, selection in pair.openBeside("X", selection: &selection) }
        #expect(!home.pair.isOpen)
        #expect(home.selection == "X")
    }
}
