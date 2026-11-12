import CoreGraphics

/// Where the chat's scroll view rests relative to its end, from `ScrollGeometry`: `offset` is `contentOffset.y`,
/// `minOffset` is `-contentInsets.top` (the offset at the top) and `maxOffset` is
/// `contentSize.height - containerSize.height - contentInsets.top` (the offset at the end). `containerSize` is the
/// bounds less the insets, bars and keyboard included (measured on iOS 26 and 27).
struct ChatScrollEdge: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
    var minOffset: CGFloat = 0

    /// Past the end over empty space (more than 1 pt), or, while following, short of it (more than 1 pt).
    /// Content shorter than the container (maxOffset below the top) never needs it: the view cannot scroll.
    func needsSettle(following: Bool) -> Bool {
        guard maxOffset > minOffset else { return false }
        return offset > maxOffset + 1 || following && offset < maxOffset - 1
    }
}
