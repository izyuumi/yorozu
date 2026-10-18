import YorozuWire

/// What ``V3Model`` needs from the link to the host: the relay session (`V3Connection`), or the App Review demo's host
/// on this device (`DemoTransport`). Both speak the same updates and events, so the model treats them alike.
protocol Transport: Actor {
    func updates() -> AsyncStream<V3Connection.Update>
    func start()
    func reconnect()
    func stop()
    func registerPush(deviceToken: String)
    func send(_ message: V3Message) -> Bool
    func send(_ event: V3Event) -> Bool
}

extension V3Connection: Transport {}
