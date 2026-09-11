import SwiftUI

@main
struct YorozuApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var model = ChatModel()

    var body: some View {
        if model.isPaired {
            ChatView(model: model)
        } else {
            ScannerView { text in
                do {
                    try model.pair(with: text)
                    return nil
                } catch {
                    return "Not a Yorozu pairing code."
                }
            }
        }
    }
}
