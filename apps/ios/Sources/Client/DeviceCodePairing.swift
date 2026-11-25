import Foundation
import YorozuWire
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Visibility and remint policy for the Mac-add device code, isolated from the mailbox wait so it can be tested without a relay.
struct DeviceCodeOffer: Equatable {
    var code: DeviceCode?
    /// True after a mailbox letter arrived or the wait expired, so this published code must not be reused.
    var spent = false

    func isVisible(pendingHostPairing: Bool, connecting: Bool) -> Bool {
        code != nil && !spent && !pendingHostPairing && !connecting
    }

    mutating func letterDropped() {
        spent = true
    }

    /// A mailbox letter arrived (accepted or not). The published code is spent because the relay re-sends that letter to every new websocket.
    mutating func letterReceived(accepted _: Bool) {
        spent = true
    }

    func shouldMint(pendingHostPairing: Bool, connecting: Bool, hasKey: Bool = true) -> Bool {
        !pendingHostPairing && !connecting && (code == nil || spent || !hasKey)
    }
}

enum DeviceAdding: Equatable {
    case asking(DeviceCode)
    case sent(DeviceCode, fingerprint: String)
    case failed(String)
}

extension AppModel {
    func addDevice(_ code: DeviceCode) {
        pendingDevice = nil
        deviceAdding = .asking(code)
        requestInvite(target: code.target, requestId: code.target == .browser ? code.box : nil)
    }

    func deliver(_ answer: PairInvite, to code: DeviceCode) {
        guard answer.target == code.target, code.target == nil || answer.requestId == code.box,
              let link = code.target == .browser ? answer.link : answer.webLink,
              let fingerprint = answer.fingerprint, let url = code.mailbox(websocket: false),
              let letter = try? code.seal(link) else {
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
            case 409?, 410?: deviceAdding = .failed(String(localized: "This code was already used or has expired. Scan the new code on the device."))
            default: deviceAdding = .failed(String(localized: "Couldn’t reach the relay. Check the connection and scan again."))
            }
        }
    }

    func showDeviceCodes() async {
        #if os(macOS)
        let name = Host.current().localizedName ?? "Mac"
        #else
        let name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
        var key: Data?
        var ownedCode: DeviceCode?
        while !Task.isCancelled {
            if pendingPairing != nil || connecting {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            var offer = DeviceCodeOffer(code: deviceCode, spent: deviceCodeSpent)
            if offer.shouldMint(pendingHostPairing: false, connecting: false, hasKey: key != nil) {
                let minted = DeviceCode.make(name: name)
                deviceCode = minted.code
                key = minted.privateKey
                deviceCodeSpent = false
                ownedCode = minted.code
            }
            guard let code = deviceCode, let currentKey = key else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            if let letter = await mailboxLetter(code, for: .seconds(600)) {
                if Task.isCancelled { break }
                if pendingPairing != nil || connecting {
                    offer.letterReceived(accepted: false)
                    deviceCodeSpent = offer.spent
                } else if let link = try? DeviceCode.open(letter, privateKey: currentKey) {
                    offer.letterReceived(accepted: true)
                    deviceCodeSpent = offer.spent
                    pairingError = submit(link)
                } else {
                    offer.letterReceived(accepted: false)
                    deviceCodeSpent = offer.spent
                }
            } else if !Task.isCancelled {
                offer.letterDropped()
                deviceCodeSpent = offer.spent
            }
        }
        if let ownedCode, deviceCode == ownedCode {
            deviceCode = nil
            deviceCodeSpent = false
        }
    }

    #if os(macOS)
    func pairWithThisMac() async -> String? {
        guard !isDemo else { return String(localized: "Exit demo mode before pairing with a host.") }
        let found: LocalPairing.Found
        do {
            found = try await LocalPairing.find()
        } catch LocalPairing.Failure.hostFailed {
            return String(localized: "The Gateway on this Mac couldn’t make a pairing code. Check `openclaw channels status`.")
        } catch {
            return String(localized: "No OpenClaw Gateway with Yorozu was found on this Mac.")
        }
        guard let payload = try? LocalPairingFile.read(path: found.path, room: found.room) else {
            return String(localized: "The Gateway on this Mac answered, but its pairing file couldn’t be read or doesn’t match it.")
        }
        pendingPairing = payload
        return nil
    }
    #endif

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
