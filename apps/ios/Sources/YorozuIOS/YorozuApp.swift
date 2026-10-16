import SwiftUI

@main
struct YorozuApp: App {
    // The delegate owns the model, so a notification reaches it with no scene on screen (#431).
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: V3AppDelegate
    #else
    @NSApplicationDelegateAdaptor private var delegate: V3AppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            V3RootView(model: delegate.model)
                #if os(macOS)
                // A window proposes no size: the least that holds the sidebar beside a chat.
                .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
                #endif
        }
        #if os(macOS)
        Settings {
            V3SettingsView(model: delegate.model)
                .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
        }
        #endif
    }
}
