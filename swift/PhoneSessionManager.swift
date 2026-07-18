import Foundation
import WatchConnectivity

final class PhoneSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneSessionManager()
    @Published var isWatchReachable = false

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // Apple Watch has no true spatial haptics, so "direction" maps to a
    // preset haptic type + timing pattern on the Watch side, not a real buzz location.
    enum HapticDirection: String {
        case left, right, up, down

        var message: [String: Any] { ["direction": rawValue] }
    }

    func sendHaptic(_ direction: HapticDirection) {
        guard WCSession.default.isReachable else {
            WCSession.default.transferUserInfo(direction.message)
            return
        }
        WCSession.default.sendMessage(direction.message, replyHandler: nil) { error in
            print("Haptic send failed: \(error.localizedDescription)")
        }
    }

    // MARK: WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isWatchReachable = session.isReachable }
    }
}
