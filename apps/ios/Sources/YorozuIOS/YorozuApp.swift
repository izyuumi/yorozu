import SwiftUI

@main
struct YorozuApp: App {
    @State private var model = V3Model()

    var body: some Scene {
        WindowGroup {
            V3RootView(model: model)
                #if os(macOS)
                // A window proposes no size: the least that holds the sidebar beside a chat.
                .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
                #endif
        }
    }
}

