import SwiftUI

@main
struct YorozuApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView(model: delegate.model)
                #if os(macOS)
                .task(id: delegate.model.isDemo) {
                    guard !delegate.model.isDemo else { return }
                    MacUpdates.start(model: delegate.model)
                }
                .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
                #endif
        }
        #if os(macOS)
        Settings {
            SettingsView(model: delegate.model)
                .yorozuTint()
                .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
        }
        .commands { MacAppCommands(model: delegate.model) }
        #endif
    }
}
