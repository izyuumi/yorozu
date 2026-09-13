import SwiftUI

extension View {
    /// Signal's swipe to reply, on the phone: dragging a bubble towards the middle of the screen
    /// pulls it along against a spring, and letting go past the threshold quotes it in the
    /// composer. Nothing at all on the Mac, where a pointer has the context menu and a trackpad
    /// swipe over a transcript means "go back".
    ///
    /// - Parameters:
    ///   - fromRight: Whether this bubble sits on the right — the user's own — which is the side
    ///     pulled leftwards. An agent's bubble is on the left and is pulled the other way.
    ///   - action: What to quote, or nil where there is nothing to reply to.
    @ViewBuilder public func swipeToReply(fromRight: Bool, action: (() -> Void)?) -> some View {
        #if os(iOS)
            if let action {
                modifier(SwipeToReply(fromRight: fromRight, action: action))
            } else {
                self
            }
        #else
            self
        #endif
    }
}

#if os(iOS)
    private struct SwipeToReply: ViewModifier {
        let fromRight: Bool
        let action: () -> Void

        /// How far the bubble has actually moved, which is the pull after resistance and not the
        /// finger's travel.
        @State private var offset: CGFloat = 0
        /// Whether letting go now would reply. Drives the filled arrow and the haptic both, so
        /// what the phone taps and what the eye sees are the same moment by construction.
        @State private var armed = false

        /// How far the bubble has to travel before letting go replies.
        private static let threshold: CGFloat = 56

        func body(content: Content) -> some View {
            content
                // Inside the offset, counter-offset by the same amount: the arrow stays where
                // the bubble's edge was and the bubble slides out from under it, which is what
                // makes the gap read as something opening rather than as the row sliding.
                .overlay(alignment: fromRight ? .trailing : .leading) { arrow.offset(x: -offset) }
                .offset(x: offset)
                // Simultaneous rather than exclusive: the scroll view keeps its own pan, so
                // dragging up and down still scrolls the thread over a bubble as it always did.
                // The angle check below is what keeps this gesture out of those drags — without
                // it, a thumb a few points off vertical would drag the message sideways.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { drag in
                            let travel = fromRight ? -drag.translation.width : drag.translation.width
                            // Towards the middle only, and shallower than 45°: anything else
                            // belongs to the scroll view or to nothing at all.
                            guard travel > 0, travel > abs(drag.translation.height) else { return }
                            offset = (fromRight ? -1 : 1) * Self.resisted(travel)
                            armed = travel >= Self.threshold
                        }
                        .onEnded { _ in
                            if armed { action() }
                            armed = false
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { offset = 0 }
                        }
                )
                // One tick, as the threshold is crossed — and none on the way back out, which is
                // why this is a closure rather than a plain trigger.
                .sensoryFeedback(trigger: armed) { _, armed in
                    armed ? .impact(weight: .light) : nil
                }
                // Screenshot only: the gesture held at its threshold, each side pulled towards
                // the middle. Here rather than in the state's own initialiser, which cannot see
                // which side this bubble is on. See ``ChatShowcase/swipe``.
                .onAppear {
                    guard ChatShowcase.swipe else { return }
                    offset = (fromRight ? -1 : 1) * Self.threshold
                    armed = true
                }
        }

        /// The pull the bubble actually takes. One-to-one with the finger up to the threshold,
        /// then a third of it, so passing the point of no return is felt as well as seen.
        private static func resisted(_ travel: CGFloat) -> CGFloat {
            travel <= threshold ? travel : threshold + (travel - threshold) / 3
        }

        /// The reply arrow in the gap the bubble leaves: fading in with the pull and filling in
        /// once letting go would reply.
        private var arrow: some View {
            let progress = min(abs(offset) / Self.threshold, 1)
            return Image(systemName: armed ? "arrowshape.turn.up.left.circle.fill" : "arrowshape.turn.up.left.circle")
                .font(.title3)
                .foregroundStyle(.tint)
                .opacity(progress)
                .scaleEffect(0.7 + 0.3 * progress)
                .padding(.horizontal, 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
#endif
