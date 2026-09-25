import SwiftUI

/// One line that shows all of its text: in place when it fits the width it is offered,
/// otherwise by scrolling to the end and back now and then. Widths come from layout —
/// the bar decides how much room the title has, this only compares.
struct MarqueeText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, (textWidth - containerWidth).rounded()) }
    private static let pointsPerSecond: CGFloat = 30

    var body: some View {
        if reduceMotion {
            Text(text).lineLimit(1)
        } else {
            Text(text)
                .lineLimit(1)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
                .offset(x: offset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { containerWidth = $0 }
                .task(id: overflow) {
                    offset = 0
                    guard overflow > 0 else { return }
                    let travel = Double(overflow / Self.pointsPerSecond)
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation(.linear(duration: travel)) { offset = -overflow }
                        try? await Task.sleep(for: .seconds(travel + 2))
                        withAnimation(.linear(duration: travel)) { offset = 0 }
                    }
                }
        }
    }
}
