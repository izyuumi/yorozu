// Inert iOS Simulator reproducer for the secretary-history container boundary.
// No Yorozu session, network, account, shared defaults, or production data.
// Default: corrected composition. --before: original outer safeAreaInset.
// Optional: --light, --accessibility. See docs/verification/thread-history-toolbar.md.
import SwiftUI
@main struct Fixture: App {
 var body: some Scene {
  WindowGroup {
   Content()
    .preferredColorScheme(CommandLine.arguments.contains("--light") ? .light : .dark)
    .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--accessibility") ? .accessibility5 : .large)
  }
 }
}
struct Content: View {
 @State var query = ""
 @ViewBuilder var body: some View {
  if CommandLine.arguments.contains("--before") {
   history.safeAreaInset(edge: .top, spacing: 0) { header }
  } else {
   VStack(spacing: 0) { header; history }
  }
 }
 var header: some View {
  HStack { Button("Yorozu", systemImage: "bubble.left.and.bubble.right") {}; Spacer() }
   .padding(.horizontal).padding(.vertical, 8).background(Color(.systemBackground))
 }
 var history: some View {
  NavigationStack {
   List { Section("Today") { VStack(alignment: .leading) { Label("Yorozu", systemImage: "sparkle"); Text("workspace").foregroundStyle(.secondary) } } }
    .listStyle(.plain)
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search threads")
    .navigationTitle("Threads").toolbarTitleDisplayMode(.inline)
    .toolbar {
     ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") {} }
     ToolbarItem(placement: .topBarTrailing) { Button("New thread", systemImage: "square.and.pencil") {} }
    }
  }
 }
}
