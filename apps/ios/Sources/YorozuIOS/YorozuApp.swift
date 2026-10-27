import SwiftUI

@main
struct YorozuApp: App {
    // The delegate owns the model, so a notification reaches it with no scene on screen (#431).
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView(model: delegate.model)
                #if os(macOS)
                // Sparkle and, once, the move from 0.5 (docs/upgrade-from-0.5.md).
                .task(id: delegate.model.isDemo) {
                    guard !delegate.model.isDemo else { return }
                    MacUpdates.start(model: delegate.model)
                    await MacMigrateFrom0_5.run(model: delegate.model)
                }
                // A window proposes no size: the least that holds the sidebar beside a chat.
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
