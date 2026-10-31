import SwiftUI
import YorozuWire

/// Why chatting is held up: the relay is out of reach, the Gateway is down, or a turn has gone quiet.
enum StatusBanner: Equatable {
    case relay, gateway, stalled

    @MainActor init?(model: AppModel, convId: String?) {
        switch model.outage {
        case .offline: self = .relay
        case .hostOffline: self = .gateway
        default:
            guard let convId, model.stalled.contains(convId) else { return nil }
            self = .stalled
        }
    }

    var text: String {
        switch self {
        case .relay: String(localized: "Can’t reach the relay. Retrying…")
        case .gateway: String(localized: "OpenClaw Gateway is offline. Messages will send when it’s back.")
        case .stalled: String(localized: "The agent hasn’t responded in 5 minutes.")
        }
    }

    var symbol: String {
        switch self {
        case .relay: "wifi.slash"
        case .gateway: "bolt.horizontal.circle"
        case .stalled: "hourglass"
        }
    }

    @MainActor private static var announced: (banner: StatusBanner, at: Date)?

    /// The chat and the list can show the same banner side by side; VoiceOver hears it once.
    @MainActor static func announce(_ banner: StatusBanner) {
        if let announced, announced.banner == banner, announced.at.timeIntervalSinceNow > -2 { return }
        announced = (banner, .now)
        AccessibilityNotification.Announcement(banner.text).post()
    }
}

extension View {
    func statusBanner(_ banner: StatusBanner?) -> some View {
        modifier(StatusBannerBar(banner: banner))
    }
}

private struct StatusBannerBar: ViewModifier {
    let banner: StatusBanner?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, macOS 26, *) {
                content.safeAreaBar(edge: .top, spacing: 0) { bar }
            } else {
                content.safeAreaInset(edge: .top, spacing: 0) { bar.background(.bar) }
            }
        }
        .animation(.snappy, value: banner)
        .onChange(of: banner) { _, new in
            if let new { StatusBanner.announce(new) }
        }
    }

    @ViewBuilder private var bar: some View {
        if let banner {
            Label {
                Text(banner.text)
            } icon: {
                Image(systemName: banner.symbol).foregroundStyle(YorozuPalette.warning)
            }
            .textStyle(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LayoutMetrics.gutter)
            .padding(.vertical, LayoutMetrics.inner)
            .accessibilityElement(children: .combine)
            .transition(.fromTop(reduceMotion: reduceMotion))
        }
    }
}
