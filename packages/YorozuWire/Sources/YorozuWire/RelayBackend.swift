/// What the Mac host hands every decrypted phone event to; the returned events go back to that phone.
public protocol RelayBackend: Sendable {
    func handle(_ e: YorozuEvent) async -> [YorozuEvent]
}
