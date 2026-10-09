import AppKit
import Combine
import SwiftUI

/// The menu-bar host: a status item whose left click toggles the chat popover and whose right click offers Settings… and Quit.
/// AppKit rather than `MenuBarExtra`, which has no public way to open its window from code (the global shortcut and
/// notification taps open it).
@MainActor final class MenuBarHost: NSObject, NSPopoverDelegate {
    /// The popover's size, the one size this component owns: nothing proposes one to an `NSPopover`.
    static let popoverSize = NSSize(width: 420, height: 744)
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let dot = AttentionDot()
    private let attention = AttentionCenter.shared
    private var shortcut: GlobalShortcut?
    private var watching: AnyCancellable?
    private var working = false
    /// SwiftUI's `openSettings`, captured from a view because AppKit has no supported way to open a `Settings` scene.
    fileprivate var openSettingsAction: OpenSettingsAction?
    /// A transient popover closes on the mouse-down that lands on the icon; its mouse-up must not reopen it.
    private var closedAt = Date.distantPast

    init(model: AppModel) {
        super.init()
        let content = NSHostingController(rootView: PopoverContent(model: model) { [weak self] in self?.showSettings() })
        content.sizingOptions = []
        popover.contentViewController = content
        popover.contentSize = Self.popoverSize
        popover.behavior = .transient
        popover.delegate = self
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Yorozu"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        attention.onOpen = { [weak self] in self?.open() }
        attention.notificationsEnabled = { [weak model] in
            model?.resolved.map { $0.config.notifications.enabled && $0.config.notifications.destination == .mac } ?? true
        }
        shortcut = GlobalShortcut { [weak self] in self?.toggle() }
        guard let button = item.button else { return }
        button.target = self; button.action = #selector(clicked(_:)); button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        dot.isHidden = true; dot.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]; button.addSubview(dot)
        // Invisible: follows work, the snapshot and the shortcut setting, and keeps `openSettings` for the menu, from launch on.
        let tracker = NSHostingView(rootView: StatusTracker(model: model, host: self))
        tracker.frame = .zero; button.addSubview(tracker)
        watching = attention.$unseen.receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshIcon() } }
        refreshIcon() // never blank, even before the tracker view appears
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            open()
        }
    }

    /// Shows the popover; already shown, it stays.
    func open() {
        guard !popover.isShown, let button = item.button else { return }
        NSApp.activate() // An LSUIElement app must activate for the composer to take keys.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// The global shortcut: opens the popover, or closes it when it is shown.
    func toggle() { popover.isShown ? popover.performClose(nil) : open() }

    func popoverDidClose(_ notification: Notification) { closedAt = Date(); attention.popoverAtBottom = false }

    @objc private func showSettings() {
        popover.performClose(nil)
        NSApp.activate()
        openSettingsAction?()
    }

    fileprivate func show(working: Bool) { self.working = working; refreshIcon() }

    /// `[general] global_shortcut`, applied at launch and whenever the config changes it; a problem goes to the status line.
    fileprivate func applyShortcut(_ spec: String, model: AppModel) {
        if let problem = shortcut?.update(spec) { model.status = problem }
    }

    private func refreshIcon() {
        guard let button = item.button else { return }
        let alert = !attention.unseen.isEmpty
        button.image = Logo.image(working: working, notched: alert)
        button.setAccessibilityLabel(alert ? String(localized: "Yorozu, new result") : working ? String(localized: "Yorozu, working") : "Yorozu")
        dot.isHidden = !alert
        // The dot sits in the logo's top-right notch; the button centers its image.
        let origin = NSPoint(x: (button.bounds.width - Logo.side) / 2, y: (button.bounds.height - Logo.side) / 2)
        let center = NSPoint(x: origin.x + Logo.notch.x, y: button.isFlipped ? origin.y + Logo.side - Logo.notch.y : origin.y + Logo.notch.y)
        dot.frame = NSRect(x: center.x - AttentionDot.radius, y: center.y - AttentionDot.radius, width: 2 * AttentionDot.radius, height: 2 * AttentionDot.radius)
    }
}

/// The Yorozu mark as a menu-bar template image: two crossed loops around a center dot, from the app icon's geometry
/// (`apps/ios/Resources/AppIcon.icon`, 1024-point canvas). Working dims the center dot; attention cuts a notch for the dot.
private enum Logo {
    static let side: CGFloat = 18
    /// The attention notch's center, in the image's unflipped coordinates.
    static let notch = NSPoint(x: 14.6, y: 14.4)

    static func image(working: Bool, notched: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.set()
            context.saveGraphicsState()
            // The crossed loops span about 859 of the icon's 1024 points; fit them in 17 with a half-point margin.
            let scale = 17 / 859.0, transform = NSAffineTransform()
            transform.translateX(by: side / 2, yBy: side / 2); transform.scale(by: scale); transform.concat()
            for angle in [45.0, -45.0] {
                let loop = NSBezierPath(roundedRect: NSRect(x: -170, y: -365.5, width: 340, height: 731), xRadius: 170, yRadius: 170)
                let turn = NSAffineTransform(); turn.rotate(byDegrees: angle); loop.transform(using: turn as AffineTransform)
                loop.lineWidth = 72.25; loop.stroke()
            }
            context.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: -104.125, y: -104.125, width: 208.25, height: 208.25)).fill()
            context.compositingOperation = .sourceOver
            NSColor.black.withAlphaComponent(working ? 0.35 : 1).set()
            NSBezierPath(ovalIn: NSRect(x: -65.875, y: -65.875, width: 131.75, height: 131.75)).fill()
            context.restoreGraphicsState()
            if notched {
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: notch.x - 3.9, y: notch.y - 3.9, width: 7.8, height: 7.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The vermilion attention dot: drawn over the template logo so the logo keeps adapting to light and dark menu bars.
private final class AttentionDot: NSView {
    static let radius: CGFloat = 2.7
    override func draw(_ dirtyRect: NSRect) {
        (NSColor(named: "AccentColor") ?? .systemRed).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private struct StatusTracker: View {
    @ObservedObject var model: AppModel
    let host: MenuBarHost
    @Environment(\.openSettings) private var openSettings
    /// The config reloads without publishing; the shortcut setting is re-read every 2 s (a string compare when unchanged).
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        Color.clear
            .onAppear { host.openSettingsAction = openSettings }
            .onChange(of: model.working, initial: true) { _, working in host.show(working: working) }
            .onChange(of: model.snapshot, initial: true) { _, snapshot in AttentionCenter.shared.ingest(snapshot) }
            .onReceive(tick) { _ in if let spec = model.resolved?.config.general.globalShortcut { host.applyShortcut(spec, model: model) } }
    }
}
