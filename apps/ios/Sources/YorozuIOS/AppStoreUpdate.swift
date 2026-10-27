#if os(iOS)
import Foundation
import StoreKit

@MainActor @Observable
final class AppStoreUpdate {
    struct Available: Equatable {
        let version: String
        let url: URL
    }

    static let shared = AppStoreUpdate()

    private(set) var available: Available?

    private static let versionKey = "appStoreUpdate.version"
    private static let urlKey = "appStoreUpdate.url"
    private static let checkedKey = "appStoreUpdate.checkedAt"
    private static let dismissedKey = "appStoreUpdate.dismissed"
    private static let interval: TimeInterval = 24 * 60 * 60

    private var checking = false

    private init() {
        let defaults = UserDefaults.standard
        if let version = defaults.string(forKey: Self.versionKey),
           let url = defaults.url(forKey: Self.urlKey) {
            show(version: version, url: url)
        }
    }

    func check(isDemo: Bool) async {
        guard !isDemo, !checking else { return }
        let defaults = UserDefaults.standard
        let checkedAt = defaults.double(forKey: Self.checkedKey)
        guard Date.now.timeIntervalSince1970 - checkedAt >= Self.interval else { return }
        checking = true
        defer { checking = false }
        guard await Self.fromAppStore() else { return }
        defaults.set(Date.now.timeIntervalSince1970, forKey: Self.checkedKey)
        guard let found = await Self.lookup() else { return }
        defaults.set(found.version, forKey: Self.versionKey)
        defaults.set(found.url, forKey: Self.urlKey)
        show(version: found.version, url: found.url)
    }

    func dismiss() {
        guard let available else { return }
        UserDefaults.standard.set(available.version, forKey: Self.dismissedKey)
        self.available = nil
    }

    private func show(version: String, url: URL) {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
        available = Self.isNewer(version, than: current) && version != dismissed ? Available(version: version, url: url) : nil
    }

    private static func fromAppStore() async -> Bool {
        guard case .verified(let transaction)? = try? await AppTransaction.shared else { return false }
        return transaction.environment == .production
    }

    private static func lookup() async -> Available? {
        guard let bundleId = Bundle.main.bundleIdentifier,
              var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        components.queryItems = [URLQueryItem(name: "bundleId", value: bundleId)]
        if let region = Locale.current.region?.identifier, region.count == 2 {
            components.queryItems?.append(URLQueryItem(name: "country", value: region.lowercased()))
        }
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(Lookup.self, from: data).results.first,
              let store = URL(string: result.trackViewUrl) else { return nil }
        return Available(version: result.version, url: store)
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Lookup: Decodable {
        struct Result: Decodable {
            let version: String
            let trackViewUrl: String
        }
        let results: [Result]
    }
}
#endif
