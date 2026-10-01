import Foundation

/// Navigation never owns a conversation or mutates its persisted composer.
public enum AppDestination: String, Hashable, Sendable {
    case chat, schedules, settings
}
