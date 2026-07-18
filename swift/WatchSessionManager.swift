import Foundation
import WatchConnectivity
import WatchKit

final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()
    @Published var lastDirection: String = "-"

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }

    private func handle(_ message: [String: Any]) {
        guard let direction = message["direction"] as? String else { return }
        DispatchQueue.main.async {
            self.lastDirection = direction
            self.playHaptic(for: direction)
        }
    }

    // Apple Watch only exposes preset haptic types -- no custom patterns --
    // so each direction gets its own preset/repeat combo as a stand-in
    // for "spatial" feedback. Tune these mappings during testing.
    private func playHaptic(for direction: String) {
        let device = WKInterfaceDevice.current()
        switch direction {
        case "left":
            device.play(.directionDown)
        case "right":
            device.play(.directionUp)
        case "up":
            device.play(.notification)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { device.play(.notification) }
        case "down":
            device.play(.failure) // distinct pattern for drop-off warning
        default:
            device.play(.click)
        }
    }
}
