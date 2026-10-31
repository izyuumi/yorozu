import SwiftUI

struct NoticePill: View {
    let notice: InAppNotice
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: LayoutMetrics.inner) {
                Image(systemName: "bubble.left.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(notice.title).textStyle(.subheadline, weight: .semibold).lineLimit(1)
                    Text(notice.text).textStyle(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, LayoutMetrics.stack)
            .padding(.vertical, LayoutMetrics.inner)
            .frame(maxWidth: LayoutMetrics.readingWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .yorozuGlass(in: Capsule())
        .padding(.horizontal, LayoutMetrics.gutter)
        .gesture(DragGesture(minimumDistance: 8).onEnded { if $0.translation.height < 0 { dismiss() } })
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the conversation"))
        .accessibilityAddTraits(.isButton)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(3))
            dismiss()
        }
    }
}

extension View {
    func inAppNotices(_ model: AppModel, open: @escaping (String) -> Void) -> some View {
        modifier(InAppNotices(model: model, open: open))
    }
}

private struct InAppNotices: ViewModifier {
    let model: AppModel
    let open: (String) -> Void
    @AppStorage(NoticeHaptics.key) private var haptics = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = model.notice {
                    NoticePill(notice: notice) {
                        model.notice = nil
                        open(notice.convId)
                    } dismiss: {
                        if model.notice?.id == notice.id { model.notice = nil }
                    }
                    .id(notice.id)
                    .transition(.fromTop(reduceMotion: reduceMotion))
                }
            }
            .animation(.snappy, value: model.notice?.id)
            .sensoryFeedback(.impact(weight: .light), trigger: model.notice?.id) { _, new in haptics && new != nil }
    }
}
