import SwiftUI
import AppKit
import ProjectXCore

/// The popover's content: header with Search and the ⋯ menu, the status line, the mode banner and notices, the ⌘F bar,
/// then the main chat. It fills whatever the popover gives it.
struct PopoverContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    @StateObject private var search = ChatSearch()
    private enum Metrics { static let dot: CGFloat = 6 }
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            header
            statusLine
            if model.runtimeMode != .live {
                VStack(alignment: .leading,spacing: 6) {
                    Label(model.runtimeMode.bannerTitle,systemImage: "exclamationmark.triangle.fill").font(.headline)
                    Text(model.runtimeMode.explanation).font(.callout).fixedSize(horizontal: false,vertical: true)
                    if model.runtimeMode == .fixture && !model.fixtureAcknowledged {
                        Button("I understand: enable synthetic TEST input") { model.fixtureAcknowledged = true }
                            .accessibilityIdentifier("acknowledgeSyntheticFixture")
                    }
                }.frame(maxWidth: .infinity,alignment: .leading).padding(12)
                    .background(Color.orange.opacity(0.18)).accessibilityElement(children: .contain)
            }
            if let notice = model.harnessNotice {
                Text(notice).font(.callout).foregroundStyle(ChatPalette.warning).lineLimit(2).truncationMode(.tail).help(notice)
                    .textSelection(.enabled).padding(.horizontal).padding(.bottom,6)
            }
            if search.shown { SearchBar(search: search).padding(.horizontal,10).padding(.bottom,8) }
            Divider()
            MainChat(model: model,search: search)
        }
        .background { Button("Search",action: showSearch).keyboardShortcut("f").hidden() }
        .task(id: search.shown ? search.query : nil) {
            guard search.shown else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await search.run(model,timeline: Set(model.timeline.map(\.id)))
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(model.runtimeMode.windowTitle).font(.headline).lineLimit(1)
            if model.working { ProgressView().controlSize(.small).help("Working on it").accessibilityLabel("Working") }
            Spacer()
            HStack(spacing: 2) {
                Button(action: showSearch) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.accessoryBar).help("Search (⌘F)").accessibilityLabel("Search")
                Menu {
                    Button("Search",action: showSearch).keyboardShortcut("f")
                    Button("Settings…",action: openSettings).keyboardShortcut(",")
                    Divider()
                    Button("Quit Yorozu") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More")
            }
            .padding(2).background(.thinMaterial,in: Capsule()).overlay { Capsule().strokeBorder(.separator,lineWidth: 0.5) }
        }.padding(.leading,16).padding(.trailing,10).padding(.top,10).padding(.bottom,2)
    }

    /// One caption line: the CLI fallback with Connect…, else startup progress or the last error, else the harness in use.
    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 6) {
            if let notice = model.nativeNotice {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning).accessibilityHidden(true)
                Text(notice).lineLimit(1).truncationMode(.tail).help(model.nativeNoticeDetail)
                Spacer()
                Button("Connect…") { model.showEnrollment(); openSettings() }.buttonStyle(.link)
            } else if let status = model.status {
                Text(status).lineLimit(1).truncationMode(.tail).help(model.statusDetail ?? status).textSelection(.enabled)
            } else if let label = model.harnessLabel {
                Circle().fill(.green).frame(width: Metrics.dot,height: Metrics.dot).accessibilityHidden(true)
                Text(label).lineLimit(1).truncationMode(.tail)
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,16).padding(.bottom,8)
    }

    private func showSearch() { search.shown = true }
}

/// No messages yet (approved design): what Yorozu does, an example that fills the composer, and where memory lives.
struct EmptyChat: View {
    @ObservedObject var model: AppModel
    private enum Metrics { static let mark: CGFloat = 44, exampleRadius: CGFloat = 12 }
    private let example = String(localized: "Find three quiet mechanical keyboards under ¥25,000 and pick one.")
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: Metrics.mark,weight: .light)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text("Ask Yorozu anything").font(.title3.weight(.semibold))
                Text("Quick questions are answered right here. Bigger work (research, writing, code) runs in the background, and the result comes back to this chat.")
                    .foregroundStyle(.secondary)
                Text("For example").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top,8)
                Button { model.draft = example } label: {
                    Text(example).multilineTextAlignment(.leading).padding(.horizontal,12).padding(.vertical,8)
                        .background(.regularMaterial,in: RoundedRectangle(cornerRadius: Metrics.exampleRadius,style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: Metrics.exampleRadius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
                }.buttonStyle(.plain).disabled(!model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged)).help("Put this in the message field")
                Text("Yorozu remembers what matters on its own, in Markdown files you own.").font(.caption).foregroundStyle(.secondary).padding(.top,10)
            }
            .multilineTextAlignment(.center).padding(.horizontal,34).padding(.vertical,24).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center,for: .alignment)
    }
}
