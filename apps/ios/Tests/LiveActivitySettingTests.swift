import Foundation
import Testing

/// Runs `body` with defaults of its own, removed afterwards.
private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "LiveActivitySettingTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

struct LiveActivitySettingTests {
    @Test func offWithNothingStored() throws {
        try withDefaults { #expect(!LiveActivitySetting.enabled($0)) }
    }

    @Test func followsTheStoredValue() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: LiveActivitySetting.key)
            #expect(LiveActivitySetting.enabled(defaults))
            defaults.set(false, forKey: LiveActivitySetting.key)
            #expect(!LiveActivitySetting.enabled(defaults))
        }
    }

    @Test func ignoresTheLegacyValue() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: LiveActivitySetting.legacyKey)
            #expect(!LiveActivitySetting.enabled(defaults))
        }
    }

    @Test func dropLegacyKeepsTheSetting() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: LiveActivitySetting.legacyKey)
            defaults.set(true, forKey: LiveActivitySetting.key)
            LiveActivitySetting.dropLegacy(defaults)
            #expect(defaults.object(forKey: LiveActivitySetting.legacyKey) == nil)
            #expect(LiveActivitySetting.enabled(defaults))
        }
    }

    @Test func dropLegacyLeavesTheSettingUnset() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: LiveActivitySetting.legacyKey)
            LiveActivitySetting.dropLegacy(defaults)
            #expect(defaults.object(forKey: LiveActivitySetting.legacyKey) == nil)
            #expect(defaults.object(forKey: LiveActivitySetting.key) == nil)
            #expect(!LiveActivitySetting.enabled(defaults))
        }
    }
}
