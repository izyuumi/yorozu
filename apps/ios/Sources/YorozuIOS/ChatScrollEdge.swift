import CoreGraphics

struct ChatScrollEdge: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
    var minOffset: CGFloat = 0

    func needsSettle(following: Bool) -> Bool {
        guard maxOffset > minOffset else { return false }
        return offset > maxOffset + 1 || following && offset < maxOffset - 1
    }
}
