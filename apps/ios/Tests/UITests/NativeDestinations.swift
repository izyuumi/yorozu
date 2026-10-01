import XCTest

/// iPhone exposes a TabBar; iPad exposes the native top destination buttons. Keep the
/// platform's presentation and exclude the chat's separate connection/Settings control.
@MainActor
func nativeDestination(_ title: String, in app: XCUIApplication) -> XCUIElement {
    let tab = app.tabBars.buttons[title]
    if tab.exists { return tab }
    return app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", title, "chat-settings")).firstMatch
}
