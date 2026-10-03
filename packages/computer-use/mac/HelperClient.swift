import Foundation

/// One admitted attempt per client, on a background queue. Keep the client alive
/// until completion. The trusted app owns admission, single-desktop ownership and
/// restart reconciliation. Never pass model-generated launch requests here.
final class ComputerUseHelperClient {
    private let lock = NSLock()
    private var used = false

    func run(bundle: URL, request: Data, nativeAuthorized: Bool = false,
             completion: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        let alreadyUsed = used
        used = true
        lock.unlock()
        guard !alreadyUsed, request.count <= 65536,
              let requestJSON = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let goal = requestJSON["goal"] as? [String: Any],
              let expectedIDs = goal["ids"] as? [String: String] else {
            completion(.failure(Failure.invalidRequest)); return
        }
        DispatchQueue.global().async {
            let process = Process()
            let input = Pipe(), output = Pipe()
            process.executableURL = bundle.appendingPathComponent("Contents/MacOS/yorozu-computer-use-helper")
            process.arguments = [nativeAuthorized ? "--native-stdio" : "--check-stdio"]
            process.environment = [:] // No inherited provider credentials or loader overrides.
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Missing/hung output is unknown, never permission to replay.
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 130, execute: timeout)
                defer { timeout.cancel() }
                var size = UInt32(request.count).bigEndian
                var frame = withUnsafeBytes(of: &size) { Data($0) }
                frame.append(request)
                try input.fileHandleForWriting.write(contentsOf: frame)
                try input.fileHandleForWriting.close()
                func readExactly(_ count: Int) throws -> Data {
                    var data = Data()
                    while data.count < count {
                        guard let chunk = try output.fileHandleForReading.read(upToCount: count-data.count), !chunk.isEmpty else {
                            throw Failure.unknownOutcome
                        }
                        data.append(chunk)
                    }
                    return data
                }
                let header = try readExactly(4)
                let count = header.reduce(0) { ($0 << 8) | Int($1) }
                guard count <= 65536 else { throw Failure.unknownOutcome }
                let response = try readExactly(count)
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw Failure.unknownOutcome }
                guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      envelope["version"] as? Int == 1,
                      let outcome = envelope["outcome"] as? [String: Any],
                      outcome["ids"] as? [String: String] == expectedIDs,
                      let status = outcome["status"] as? String,
                      ["done", "stuck", "stopped"].contains(status) else {
                    throw Failure.unknownOutcome
                }
                completion(.success(response))
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                completion(.failure(error))
            }
        }
    }
    enum Failure: Error { case invalidRequest, unknownOutcome }
}
