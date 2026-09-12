/// Native tool host. Node cannot call Accessibility, ScreenCaptureKit or CGEvent, so the
/// runtime spawns this helper once and multiplexes every native tool call over its pipes:
/// one JSON request per line on stdin, one JSON response per line on stdout. Requests carry
/// an `id` that the response echoes back, so the runtime can have several in flight.
/// See docs/spec-v1.html section 3.

import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import YorozuPermissions

/// A failure the runtime should see as `{"ok":false,"error":…}` rather than a crash.
///
/// `permission` names the grant that is missing, when that is what went wrong. It travels as
/// its own field rather than being read back out of the message, so the runtime can turn it
/// into a `request_permission` call without matching on English. See tools/permissions.ts.
struct Failure: Error {
    let message: String
    let permission: Permission?
    init(_ message: String, permission: Permission? = nil) {
        self.message = message
        self.permission = permission
    }
}

@MainActor
enum Native {
    /// An AX tree can run to thousands of nodes and the model pays for every line, so the
    /// walk is bounded in both directions.
    static let maxDepth = 12
    static let maxNodes = 400

    /// Element IDs handed out by the last `ax.read`, so `input.click {id}` can resolve one.
    /// AXUIElement refs are only meaningful inside this process, which is why they stay here
    /// and only the IDs cross the pipe.
    static var elements: [String: AXUIElement] = [:]

    static let source = CGEventSource(stateID: .combinedSessionState)

    // MARK: - Accessibility

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// An attribute as text. Numbers and booleans read back as values worth showing too.
    static func text(_ element: AXUIElement, _ name: String) -> String? {
        switch attribute(element, name) {
        case let string as String: string.isEmpty ? nil : string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// A conditional downcast to a CoreFoundation type always succeeds, so the type ID is
    /// what actually tells one AX attribute from another.
    static func cast<T: AnyObject>(_ raw: CFTypeRef?, _ typeID: CFTypeID) -> T? {
        guard let raw, CFGetTypeID(raw) == typeID else { return nil }
        return unsafeDowncast(raw, to: T.self)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        let typeID = AXValueGetTypeID()
        guard let position: AXValue = cast(attribute(element, kAXPositionAttribute), typeID),
              let size: AXValue = cast(attribute(element, kAXSizeAttribute), typeID)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The element named by a previous `ax.read` ID, else the frontmost window.
    static func rootWindow(_ windowRef: String?) -> AXUIElement? {
        if let windowRef { return elements[windowRef] }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let window: AXUIElement? = cast(
            attribute(app, kAXFocusedWindowAttribute),
            AXUIElementGetTypeID()
        )
        if let window { return window }
        return (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    /// Depth-limited walk. Zero-sized and hidden elements are dropped with their subtrees:
    /// they are most of what makes a real tree unreadable, and none of them can be clicked.
    static func node(_ element: AXUIElement, depth: Int) -> [String: Any]? {
        if elements.count >= maxNodes { return nil }
        let box = frame(element)
        if let box, box.width < 1 || box.height < 1 { return nil }
        if attribute(element, "AXHidden") as? Bool == true { return nil }

        let id = "e\(elements.count + 1)"
        elements[id] = element

        var result: [String: Any] = [
            "id": id,
            "role": text(element, kAXRoleAttribute) ?? "AXUnknown",
        ]
        // A button's label is as likely to be its description as its title.
        if let title = text(element, kAXTitleAttribute) ?? text(element, kAXDescriptionAttribute) {
            result["title"] = title
        }
        if let value = text(element, kAXValueAttribute) { result["value"] = value }
        if let box {
            result["frame"] = ["x": box.origin.x, "y": box.origin.y, "w": box.width, "h": box.height]
        }
        if depth < maxDepth, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            let kids = children.compactMap { node($0, depth: depth + 1) }
            if !kids.isEmpty { result["children"] = kids }
        }
        return result
    }

    static func axRead(_ request: [String: Any]) throws -> [String: Any] {
        guard AXIsProcessTrusted() else {
            throw Failure("Accessibility is not granted", permission: .accessibility)
        }
        // IDs are only valid until the next read: the tree they pointed into is gone.
        elements = [:]
        guard let root = rootWindow(request["windowRef"] as? String) else {
            throw Failure("no frontmost window")
        }
        let tree = node(root, depth: 0) ?? [:]
        return [
            "app": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            "tree": tree,
            "count": elements.count,
        ]
    }

    // MARK: - Screenshot

    static func screenCapture() async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw Failure("Screen Recording is not granted", permission: .screenRecording)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { throw Failure("no display") }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure("PNG encoding failed") }
        return [
            "png": png.base64EncodedString(),
            "width": image.width,
            "height": image.height,
        ]
    }

    // MARK: - Input

    /// Where a click lands: the centre of an `ax.read` element, or explicit coordinates.
    static func point(_ request: [String: Any]) throws -> CGPoint {
        if let id = request["id"] as? String {
            guard let element = elements[id] else {
                throw Failure("unknown element: \(id) — call ax.read again")
            }
            guard let box = frame(element) else { throw Failure("element has no frame: \(id)") }
            return CGPoint(x: box.midX, y: box.midY)
        }
        guard let x = request["x"] as? Double, let y = request["y"] as? Double else {
            throw Failure("pass an element id, or x and y")
        }
        return CGPoint(x: x, y: y)
    }

    /// Posting a CGEvent without Input Monitoring does not fail — it is simply dropped, and
    /// the agent sees a click that did nothing. Checked up front so it is an error instead.
    static func requireInput() throws {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw Failure("Input Monitoring is not granted", permission: .inputMonitoring)
        }
    }

    static func click(_ request: [String: Any]) throws -> [String: Any] {
        try requireInput()
        let at = try point(request)
        for phase in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(
                mouseEventSource: source,
                mouseType: phase,
                mouseCursorPosition: at,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        return ["clicked": ["x": at.x, "y": at.y]]
    }

    /// Typed as Unicode rather than as key codes, so the text is layout-independent.
    static func typeText(_ text: String) throws -> [String: Any] {
        try requireInput()
        for character in text {
            var units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event.post(tap: .cghidEventTap)
            }
        }
        return ["typed": text.count]
    }

    /// The keys a shortcut is actually built from. Anything else is text: use input.type.
    static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "opt": .maskAlternate, "option": .maskAlternate,
        "fn": .maskSecondaryFn,
    ]

    static func key(_ request: [String: Any]) throws -> [String: Any] {
        try requireInput()
        let name = (request["key"] as? String ?? "").lowercased()
        guard let code = keyCodes[name] else { throw Failure("unknown key: \(name)") }
        let names = request["modifiers"] as? [String] ?? []
        var flags = CGEventFlags()
        for modifier in names {
            guard let flag = modifierFlags[modifier.lowercased()] else {
                throw Failure("unknown modifier: \(modifier)")
            }
            flags.insert(flag)
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return ["key": name, "modifiers": names]
    }

    // MARK: - Permissions

    /// `permission.status` reads one grant, `permission.request` makes macOS show its prompt
    /// for it and answers with the state afterwards. Both are what the runtime's
    /// request_permission tool is built on, so the agent can ask for a grant mid-conversation
    /// instead of telling the user to go hunting in System Settings.
    static func permission(_ cmd: String, _ request: [String: Any]) async throws -> [String: Any] {
        let raw = request["kind"] as? String ?? ""
        guard let kind = Permission(rawValue: raw), Permission.requestable.contains(kind) else {
            throw Failure(
                "unknown permission: \(raw). One of: "
                    + Permission.requestable.map(\.rawValue).joined(separator: ", ")
            )
        }
        let granted = cmd == "permission.request" ? await kind.request() : await kind.isGranted()
        return ["kind": kind.rawValue, "title": kind.title, "granted": granted, "canPrompt": kind.canPrompt]
    }

    // MARK: - Protocol

    static func handle(_ request: [String: Any]) async -> [String: Any] {
        do {
            let cmd = request["cmd"] as? String ?? ""
            // Calendar, reminders and mail live in Apple.swift; everything else is here.
            if let result = try await Apple.handle(cmd, request) { return result }
            switch cmd {
            case "ax.read": return try axRead(request)
            case "screen.capture": return try await screenCapture()
            case "input.click": return try click(request)
            case "input.type": return try typeText(request["text"] as? String ?? "")
            case "input.key": return try key(request)
            case "permission.status", "permission.request": return try await permission(cmd, request)
            case "permission.list":
                return ["kinds": Permission.requestable.map(\.rawValue)]
            case "ping": return ["pong": true]
            case let other: throw Failure("unknown command: \(other)")
            }
        } catch let failure as Failure {
            var response: [String: Any] = ["error": failure.message]
            if let permission = failure.permission { response["permission"] = permission.rawValue }
            return response
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    static func run() async {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            var response: [String: Any]
            var request: [String: Any]?
            if let data = line.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                request = parsed
                response = await handle(parsed)
            } else {
                response = ["error": "malformed request"]
            }
            response["ok"] = response["error"] == nil
            // Echoed so the runtime can match a reply to its request. Not `id`: that is an
            // element ID on the way in, and the two must not collide.
            if let rid = request?["rid"] { response["rid"] = rid }
            guard let encoded = try? JSONSerialization.data(withJSONObject: response),
                  let text = String(data: encoded, encoding: .utf8)
            else { continue }
            print(text)
            fflush(stdout)
        }
    }
}

await Native.run()
