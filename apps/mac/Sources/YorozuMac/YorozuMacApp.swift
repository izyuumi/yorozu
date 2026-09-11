import SwiftUI
import YorozuShared

@main
struct YorozuMacApp: App {
    var body: some Scene {
        MenuBarExtra("Yorozu", systemImage: "circle.dotted") {
            ThreadListView()
        }
        .menuBarExtraStyle(.window)
    }
}
