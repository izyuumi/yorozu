import Foundation
import YorozuWire
#if os(macOS)
import AppKit
#endif

enum DeviceAdding: Equatable {
    case asking(DeviceCode)
    case sent(DeviceCode, fingerprint: String)
    case failed(String)
}

extension AppModel {
    func addDevice(_ code: DeviceCode) {
        pendingDevice = nil
        deviceAdding = .asking(code)
        requestInvite()
    }

    func deliver(_ answer: PairInvite, to code: DeviceCode) {
        guard let webLink = answer.webLink, let fingerprint = answer.fingerprint, let url = code.mailbox(websocket: false),
              let letter = try? code.seal(webLink) else {
            deviceAdding = .failed(answer.error ?? String(localized: "The host could not make a pairing code."))
            return
        }
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(letter.utf8)
            let status = (try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse
            guard deviceAdding == .asking(code) else { return }
            switch status?.statusCode {
            case 204?: deviceAdding = .sent(code, fingerprint: fingerprint)
            case 409?, 410?: deviceAdding = .failed(String(localized: "This code was already used or has expired. Scan the new code on the Mac."))
            default: deviceAdding = .failed(String(localized: "Couldn’t reach the relay. Check the connection and scan again."))
            }
        }
    }

    func showDeviceCodes() async {
        #if os(macOS)
        let name = Host.current().localizedName ?? "Mac"
        #else
        let name = "Yorozu"
        #endif
        while !Task.isCancelled {
            let (code, key) = DeviceCode.make(name: name)
            deviceCode = code
            if let letter = await mailboxLetter(code, for: .seconds(600)), let link = try? DeviceCode.open(letter, privateKey: key) {
                pairingError = submit(link)
            }
        }
        deviceCode = nil
    }

    private func mailboxLetter(_ code: DeviceCode, for duration: Duration) async -> String? {
        guard let url = code.mailbox(websocket: true) else { return nil }
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end, !Task.isCancelled {
            let socket = URLSession.shared.webSocketTask(with: url)
            socket.resume()
            let letter = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    if case .string(let text)? = try? await socket.receive() { return text }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(until: end)
                    return nil
                }
                let first = await group.next() ?? nil
                socket.cancel(with: .normalClosure, reason: nil)
                group.cancelAll()
                return first
            }
            if let letter { return letter }
            try? await Task.sleep(for: .seconds(3))
        }
        return nil
    }
}
