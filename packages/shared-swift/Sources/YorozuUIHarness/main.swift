/// Offscreen SwiftUI screenshots and timing. No app bundle, window, account or network.
/// swift run --package-path packages/shared-swift YorozuUIHarness /tmp/yorozu-ui
import AppKit
import CryptoKit
import Foundation
import SwiftUI
import YorozuShared

actor HarnessTransport: ChatTransport {
    private var continuation: AsyncStream<TransportUpdate>.Continuation?
    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        self.continuation = continuation
        continuation.yield(.state(.paired))
        continuation.yield(.ownerOnline(true))
        return stream
    }
    func send(_ event: YorozuEvent) {}
    func close() { continuation?.finish() }
    func deliver(_ event: YorozuEvent) { continuation?.yield(.event(event)) }
}

@main struct Harness {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/yorozu-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let card = ApprovalCardData(actionId: "approval", actionClass: "Bash", target: "swift test --package-path packages/shared-swift", nativeAgent: .claudeCode)
        for width in [390.0, 900.0] {
            for dark in [false, true] {
                let scene = VStack(alignment: .leading, spacing: 16) {
                    Text("Native agent bridge").font(.title2)
                    UpdateStatusView(status: UpdateStatusData(phase: .countdown, version: "1.0",
                        deadline: (Date().timeIntervalSince1970 + 10) * 1000)) {}
                    ApprovalCardView(card: card) { _, _ in }
                    QuestionCardView(card: QuestionCardData(questionId: "question", question: "Which test should run next?", options: ["Shared Swift tests", "Runtime tests"], allowOther: true)) { _ in }
                    WorkRowView(work: TurnWork(startEventId: "work", entries: [], startedAt: 0, lastAt: 2000, running: false))
                    Text("Turn interrupted").font(.headline)
                    HStack { Button("Continue") {}; Button("Dismiss") {} }.buttonStyle(.bordered)
                }
                .padding(20)
                .frame(width: width, alignment: .leading)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: scene)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw NSError(domain: "UIHarness", code: 1)
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "UIHarness", code: 2)
                }
                try png.write(to: output.appendingPathComponent("native-\(Int(width))-\(dark ? "dark" : "light").png"))
                print("SCREEN native-\(Int(width))-\(dark ? "dark" : "light") \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            }
        }

        let cacheDir = output.appendingPathComponent("temporary-cache")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let transport = HarnessTransport()
        let model = ChatModel(transport: transport, cache: ThreadCache(directory: cacheDir, key: SymmetricKey(size: .bits256)))
        model.start()
        while !model.ownerOnline { try await Task.sleep(for: .milliseconds(1)) }
        let profile = CommandLine.arguments.contains("--profile")
        let iterations = profile ? 300 : 20
        var times: [Double] = []
        for iteration in 0..<iterations {
            let page = (0..<200).map { i in YorozuEvent(id: "event-\(i)", threadId: "benchmark", ts: i, agentId: "main",
                payload: .toolResult(ToolResultData(callId: "call-\(i)", ok: true, output: String(repeating: "x", count: 4096) + "\(iteration)"))) }
            let revision = model.syncRevision
            let start = ContinuousClock.now
            await transport.deliver(YorozuEvent(id: "sync-\(iteration)", threadId: "", ts: iteration, agentId: "main", payload: .syncDelta(SyncDeltaData(events: page))))
            while model.syncRevision == revision { await Task.yield() }
            let elapsed = start.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            await model.flushCache()
        }
        times.sort()
        let report = "sync page 200x4KB: n=\(iterations), median=\(times[times.count/2])ms, p95=\(times[Int(Double(times.count-1)*0.95)])ms, max=\(times.last!)ms\n"
        print(report)
        try report.write(to: output.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        model.close()
    }
}
