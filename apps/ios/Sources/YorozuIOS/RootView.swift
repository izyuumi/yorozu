import SwiftUI
import YorozuShared

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
            ThreadListView(
                threads: model.threads,
                onCreate: { model.createThread(title: $0) },
                onArchive: model.archive
            ) { thread in
                ChatView(model: model, thread: thread)
                    .toolbar {
                        Button("Unpair", systemImage: "qrcode") { model.unpair() }
                    }
            }
            .task { model.start() }
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
