import Foundation
import Combine
import WatchConnectivity

final class PhoneSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneSessionManager()
    /// True when a paired watch has the app installed — does not require the watch app to be open.
    @Published var isWatchConnected = false
    @Published var isWatchReachable = false

    /// Watch → phone requests (set by ContentView). wake_voice comes from the
    /// double-pinch gesture; scan_now from the Watch's scan button.
    var onVoiceWake: (() -> Void)?
    var onWatchScanRequest: (() -> Void)?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // Apple Watch has no true spatial haptics, so "direction" maps to a
    // preset haptic type + timing pattern on the Watch side, not a real buzz location.
    // Uses HapticSensorDirection (defined in CaneMessage.swift) directly --
    // it already mirrors /ws/haptics exactly (3 physical sensors, 3 possible
    // values), so there's no separate phone-side direction type to keep in sync.
    // The phone's intensity setting rides along with every buzz so the Watch
    // always plays at whatever strength is currently set in the phone app.
    func sendHaptic(_ direction: HapticSensorDirection) {
        let message: [String: Any] = [
            "direction": direction.rawValue,
            "intensity": AppSettings.shared.hapticIntensity.rawValue
        ]
        guard WCSession.default.isReachable else {
            WCSession.default.transferUserInfo(message)
            return
        }
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            print("Haptic send failed: \(error.localizedDescription)")
        }
    }

    /// Mirrors the phone's haptic intensity setting to the Watch.
    /// updateApplicationContext is fire-and-forget, survives the Watch app
    /// being closed, and only ever delivers the latest value — exactly the
    /// semantics a settings value needs.
    func syncHapticIntensity(_ intensity: String) {
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["hapticIntensity": intensity])
    }

    func sendSOSAlert() {
        let msg: [String: Any] = ["type": "sos_alert", "active": true]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil)
        } else {
            WCSession.default.transferUserInfo(msg)
        }
    }

    func sendSOSClear() {
        WCSession.default.transferUserInfo(["type": "sos_clear"])
    }

    func refreshWatchReachability() {
        let s = WCSession.default
        isWatchConnected = s.isReachable
        isWatchReachable = s.isReachable
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        DispatchQueue.main.async {
            switch command {
            case "wake_voice": self.onVoiceWake?()
            case "scan_now":   self.onWatchScanRequest?()
            default: break
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isWatchConnected = session.isPaired && session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
        }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchConnected = session.isPaired && session.isWatchAppInstalled
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
            self.isWatchConnected = session.isReachable
        }
    }
}