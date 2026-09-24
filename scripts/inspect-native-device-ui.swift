// Native UI validation only. Compile the ACTUAL DevicesView.swift alongside this file.
// The only substitutes are inert runtime/session dependencies; sends never leave this process.
// Build shared Swift first, then from the repository root:
// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
//   -I packages/shared-swift/.build/out/Products/Debug \
//   -L packages/shared-swift/.build/out/Products/Debug -lYorozuShared \
//   apps/mac/Sources/YorozuMac/DevicesView.swift scripts/inspect-native-device-ui.swift \
//   -o /tmp/yorozu-device-fixture
// /tmp/yorozu-device-fixture
// Screenshots go to /tmp/yorozu-devices-*.png. Window screenshots require Screen Recording.
// Fixed-coordinate clicks inspect this fixture only and never confirm removal.
import AppKit
import SwiftUI
import YorozuShared

actor InertTransport: ChatTransport {
    var continuation: AsyncStream<TransportUpdate>.Continuation?
    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        self.continuation = continuation
        continuation.yield(.state(.paired))
        continuation.yield(.ownerOnline(true))
        return stream
    }
    func send(_ event: YorozuEvent) { print("INERT_SEND \(event.id)") }
    func close() { continuation?.finish() }
    func deliver(_ event: YorozuEvent) { continuation?.yield(.event(event)) }
}
@MainActor final class Sidecar: ObservableObject {
    @Published var state = "running"
    @Published var qr: NSImage?
    @Published var pairingString: String?
    func newCode() { print("INERT_NEW_CODE") }
}
@MainActor final class MacChatSession {
    static let shared = MacChatSession()
    let transport = InertTransport()
    lazy var model = ChatModel(transport: transport)
}
@main struct DeviceFixture {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let session = MacChatSession.shared
        session.model.start()
        while !session.model.ownerOnline { await Task.yield() }
        let devices = [
            DeviceInfo(pub: "local-this-mac-key-for-fixture-only", via: .local, lastSeen: 0, online: true),
            DeviceInfo(pub: "paired-A-1234567890abcdefghijklmnopqrstuvwxyz1234567890", via: .relay, lastSeen: 0, online: true),
            DeviceInfo(pub: "paired-B-zyxwvutsrqponmlkjihgfedcba0987654321", via: .relay, lastSeen: 1, online: false),
        ]
        await session.transport.deliver(YorozuEvent(id: "fixture-devices", threadId: "", ts: 0, agentId: "main", payload: .deviceList(DeviceListData(devices: devices))))
        while session.model.devices.count != 3 { await Task.yield() }
        let sidecar = Sidecar()
        let host = NSHostingView(rootView: DevicesView(sidecar: sidecar).padding(20).frame(width: 520, height: 420).background(Color.white).environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:520,height:420), styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        try capture(host,"/tmp/yorozu-devices-inert.png")
        click(window, x: 115, y: 283)
        try await Task.sleep(for: .milliseconds(300))
        try capture(host,"/tmp/yorozu-devices-expanded.png")
        click(window, x: 115, y: 283)
        try await Task.sleep(for: .milliseconds(200))
        click(window, x: 448, y: 284)
        try await Task.sleep(for: .milliseconds(300))
        try capture(host,"/tmp/yorozu-devices-confirmation.png")
        if let sheet = window.attachedSheet, let content = sheet.contentView {
            try capture(content,"/tmp/yorozu-devices-confirmation-sheet.png")
        }
        if CommandLine.arguments.contains("--interactive") {
            try await Task.sleep(for: .seconds(30))
        }
        window.orderOut(nil)
        session.model.close()
    }
    @MainActor static func click(_ window:NSWindow, x:Double,y:Double) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:y),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            window.sendEvent(event)
        }
    }
    @MainActor static func capture(_ host: NSView, _ path:String) throws {
        host.layoutSubtreeIfNeeded()
        if let window = host.window {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-o", "-x", "-l", String(window.windowNumber), path.replacingOccurrences(of: ".png", with: "-window.png")]
            try process.run()
            process.waitUntilExit()
            print("WINDOW_CAPTURE", process.terminationStatus)
        }
        let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
        print("SCREEN \(path)")
    }
}
