import Carbon.HIToolbox

/// The optional global shortcut, `[general] global_shortcut` ("option+space"; empty is off): a Carbon hot key, which
/// needs no Accessibility permission.
@MainActor final class GlobalShortcut {
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var spec = ""

    init(action: @escaping () -> Void) { self.action = action }

    /// Registers `spec` in place of the current one. Returns a problem to show, or nil when registered or off.
    func update(_ spec: String) -> String? {
        guard spec != self.spec else { return nil }
        self.spec = spec
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard !spec.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let (key, modifiers) = Self.parse(spec) else { return String(localized: "Global shortcut not recognized: \(spec)") }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
                // Application-target events arrive on the main thread.
                MainActor.assumeIsolated { Unmanaged<GlobalShortcut>.fromOpaque(me!).takeUnretainedValue().action() }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x59525A55), id: 1) // "YRZU"
        guard RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            return String(localized: "Global shortcut \(spec) is in use by another app")
        }
        return nil
    }

    /// "option+space", "cmd+shift+y", "ctrl+f5": modifiers then one key, joined by "+". A key other than F1–F12 needs a modifier.
    static func parse(_ spec: String) -> (key: UInt32, modifiers: UInt32)? {
        var parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.popLast() else { return nil }
        var modifiers = 0
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": modifiers |= cmdKey
            case "option", "opt", "alt", "⌥": modifiers |= optionKey
            case "ctrl", "control", "⌃": modifiers |= controlKey
            case "shift", "⇧": modifiers |= shiftKey
            default: return nil
            }
        }
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        let named = ["space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape]
        // ANSI key codes 0–50 by the character they type; "\0" marks codes that type none of these.
        let ansi = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm.\0\0`"
        let key: Int
        if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...12).contains(n) { return (UInt32(fKeys[n - 1]), UInt32(modifiers)) }
        else if let code = named[name] { key = code }
        else if name.count == 1, name != "\0", let i = ansi.firstIndex(of: name.first!) { key = ansi.distance(from: ansi.startIndex, to: i) }
        else { return nil }
        return modifiers == 0 ? nil : (UInt32(key), UInt32(modifiers))
    }
}
