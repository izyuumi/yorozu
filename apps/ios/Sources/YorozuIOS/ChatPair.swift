import CoreGraphics

enum PaneSide { case left, right }

/// The detail column's panes beside the focused conversation, which is the external `selection`.
struct ChatPair {
    /// One case per layout, so a picker beside a split, a split without a second conversation, or a second pane
    /// showing the focused conversation can't be stored.
    enum Panes: Equatable { case one, picking, two(other: String, otherOnLeft: Bool) }

    var panes = Panes.one
    var fraction: CGFloat = 0.5

    var partner: String? { if case let .two(other, _) = panes { other } else { nil } }
    var partnerOnLeft: Bool { if case let .two(_, onLeft) = panes { onLeft } else { false } }
    var choosing: Bool {
        get { panes == .picking }
        set { if newValue { panes = .picking } else if panes == .picking { panes = .one } }
    }

    var isOpen: Bool { panes != .one }
    var focusedSide: PaneSide { partnerOnLeft ? .right : .left }
    private var otherSide: PaneSide { focusedSide == .left ? .right : .left }

    mutating func openBeside(_ convId: String, selection: inout String?) {
        defer { settle(selection) }
        choosing = false
        guard let current = selection, current != convId else { selection = convId; return }
        if partner == convId { return focus(otherSide, selection: &selection) }
        panes = .two(other: current, otherOnLeft: focusedSide == .left)
        selection = convId
    }

    mutating func focus(_ side: PaneSide, selection: inout String?) {
        guard side != focusedSide, let partner else { return }
        let otherOnLeft = !partnerOnLeft
        panes = selection.map { Panes.two(other: $0, otherOnLeft: otherOnLeft) } ?? .one
        selection = partner
        settle(selection)
    }

    mutating func swapSides() {
        if case let .two(other, onLeft) = panes { panes = .two(other: other, otherOnLeft: !onLeft) }
    }

    mutating func close(_ side: PaneSide, selection: inout String?) {
        if choosing { choosing = false; return }
        if side == focusedSide { selection = partner }
        panes = .one
        fraction = 0.5
    }

    mutating func show(_ convId: String, on side: PaneSide, selection: inout String?) {
        defer { settle(selection) }
        if convId == selection { return }
        if convId == partner { return focus(otherSide, selection: &selection) }
        if side == focusedSide {
            selection = convId
        } else {
            panes = .two(other: convId, otherOnLeft: partnerOnLeft)
            focus(side, selection: &selection)
        }
    }

    mutating func drop(_ convId: String, on side: PaneSide, selection: inout String?) {
        guard partner == nil, let current = selection, current != convId else { return show(convId, on: side, selection: &selection) }
        panes = .two(other: current, otherOnLeft: side == .right)
        selection = convId
    }

    mutating func selectionChanged(from old: String?, to new: String?, compact: Bool, selection: inout String?) {
        defer { settle(selection) }
        if choosing {
            // A pick puts the picker's conversation beside it; losing it (or gaining one from none) closes the picker.
            if let old, let new, old != new { panes = .two(other: old, otherOnLeft: true) } else if old != new { panes = .one }
        } else if let new, new == partner {
            let otherOnLeft = !partnerOnLeft
            panes = old.map { Panes.two(other: $0, otherOnLeft: otherOnLeft) } ?? .one
        } else if new == nil, !compact, let partner {
            panes = .one
            selection = partner
        }
    }

    func side(of convId: String, selection: String?) -> PaneSide? {
        guard partner != nil else { return nil }
        if convId == selection { return focusedSide }
        return convId == partner ? otherSide : nil
    }

    /// The second pane never shows the focused conversation.
    private mutating func settle(_ selection: String?) {
        if case let .two(other, _) = panes, other == selection { panes = .one }
    }
}
