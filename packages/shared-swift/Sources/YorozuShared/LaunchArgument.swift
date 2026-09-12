import Foundation

/// The `-name value` launch arguments both apps are driven by in tests: a simulator has no
/// camera to scan a pairing code with and nothing on either platform can be made to open a real
/// menu or share sheet on demand, so the harness injects what it needs as arguments.
///
/// Read straight from `ProcessInfo` rather than through `UserDefaults`: the argument domain
/// tries to property-list-parse the value first, and a pairing string is not a plist.
public func launchArgument(_ name: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-\(name)"), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}
