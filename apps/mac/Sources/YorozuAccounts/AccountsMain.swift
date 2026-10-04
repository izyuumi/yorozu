import Foundation
import YorozuAccountsCore

// This executable has no tool-dispatch entry point. Only the trusted host owns its pipes.
@main struct YorozuAccounts {
    @MainActor static func main() {
        let rpc = AccountsRPC(service: AccountService(backend: KeychainAccountBackend(), locks: POSIXAccountLocks(), browser: WorkspaceAccountBrowser()))
        defer { rpc.close() }
        var reader = AccountLineReader()
        func emit(_ frame: AccountLineReader.Frame) throws {
            let reply: Data
            switch frame {
            case .line(let data): reply = rpc.reply(to: data)
            case .invalid: reply = rpc.reply(to: Data())
            }
            try FileHandle.standardOutput.write(contentsOf: reply + Data([10]))
        }
        do {
            while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
                for frame in reader.accept(chunk) { try emit(frame) }
            }
            if let last = reader.finish() { try emit(last) }
        } catch { /* No native errors or input contents are logged. EOF/failure releases leases. */ }
    }
}
