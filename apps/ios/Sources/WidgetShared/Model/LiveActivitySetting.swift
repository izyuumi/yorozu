import Foundation

enum LiveActivitySetting {
    static let key = "liveActivities"
    static let legacyKey = "turnLiveActivity"

    static func enabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: key) as? Bool ?? false }
    static func dropLegacy(_ defaults: UserDefaults) { defaults.removeObject(forKey: legacyKey) }
}
