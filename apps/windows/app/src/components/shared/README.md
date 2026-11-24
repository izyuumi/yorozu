# Yorozu’s React client views

Windows/Tauri and the browser render these same React components and control
styles. The adapters supply events and state, not copied view markup. The
Windows adapter uses Tauri commands; the web adapter uses the browser pairing
and relay. These components do not open a socket, store data, or call Tauri.

Design reference: native SwiftUI `Root.swift` (pairing), `Chat.swift`
(conversation, composer), `Settings.swift` (devices) and `YorozuTheme.swift`
(default vermilion accent and system appearance). Both React clients put the
pairing link before host fingerprint approval, identify messages as You or
Yorozu, show a separate message composer, and provide a deliberate local
forget action. They share the light/dark color treatment, content spacing and
rounded user message bubble. The web's arrow control retains the spoken Send
label, and the Windows adapter retains its desktop buttons, Ctrl+Enter,
delivery marks, and retry UI.

Native iPhone/iPad/Mac stay SwiftUI, using the platform’s own QR, navigation and
system effects. Windows remains a Windows client, not a webview shipped with
browser keys; web remains limited to pairing, settings, and text chat/history.
