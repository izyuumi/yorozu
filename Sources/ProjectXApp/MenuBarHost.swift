import AppKit
import SwiftUI

/// The menu-bar host: a status item whose left click toggles the chat popover and whose right click offers Settings… and Quit.
/// AppKit rather than `MenuBarExtra`, which has no public way to open its window from code.
@MainActor final class MenuBarHost: NSObject {
    /// The popover's size, the one size this component owns: nothing proposes one to an `NSPopover`.
    static let popoverSize = NSSize(width: 420, height: 640)
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    /// SwiftUI's `openSettings`, captured from a view because AppKit has no supported way to open a `Settings` scene.
    fileprivate var openSettingsAction: OpenSettingsAction?

    init(model: AppModel) {
        super.init()
        let content = NSHostingController(rootView: PopoverContent(model: model) { [weak self] in self?.showSettings() })
        content.sizingOptions = []
        popover.contentViewController = content
        popover.contentSize = Self.popoverSize
        popover.behavior = .transient
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Yorozu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        guard let button = item.button else { return }
        button.target = self; button.action = #selector(clicked(_:)); button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Invisible: swaps the icon while work runs and keeps `openSettings` for the menu, from launch on.
        let tracker = NSHostingView(rootView: StatusTracker(model: model, host: self))
        tracker.frame = .zero; button.addSubview(tracker)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate() // An LSUIElement app must activate for the composer to take keys.
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        NSApp.activate()
        openSettingsAction?()
    }

    fileprivate func show(working: Bool) {
        let image = NSImage(systemSymbolName: working ? "ellipsis.bubble" : "bubble.left", accessibilityDescription: working ? "Yorozu, working" : "Yorozu")
        image?.isTemplate = true
        item.button?.image = image
    }
}

private struct StatusTracker: View {
    @ObservedObject var model: AppModel
    let host: MenuBarHost
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear
            .onAppear { host.openSettingsAction = openSettings }
            .onChange(of: model.working, initial: true) { _, working in host.show(working: working) }
    }
}
