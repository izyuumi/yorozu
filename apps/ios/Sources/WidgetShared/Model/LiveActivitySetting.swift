import Foundation

/// The Live Activity switch (Settings › Live Activities): off until the owner turns it on. It lives in the app's
/// standard defaults, so only the app reads it (the extensions compile this file but never call it).
enum LiveActivitySetting {
    static let key = "liveActivities"
    /// The switch from before it was opt-in, on by default; its value is dropped at launch and never read.
    static let legacyKey = "turnLiveActivity"

    static func enabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: key) as? Bool ?? false }
    static func dropLegacy(_ defaults: UserDefaults) { defaults.removeObject(forKey: legacyKey) }
}
