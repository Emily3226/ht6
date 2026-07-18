import Foundation
import WatchConnectivity
import WatchKit
internal import Combine

final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    @Published var lastDirection: String = "-"
    @Published var isPhoneReachable: Bool = false
    @Published var sosActive: Bool = false

    @Published var hapticIntensity: String = "medium" {
        didSet { UserDefaults.standard.set(hapticIntensity, forKey: "watchHapticIntensity") }
    }
    @Published var audioEnabled: Bool = true {
        didSet { UserDefaults.standard.set(audioEnabled, forKey: "watchAudioEnabled") }
    }

    private override init() {
        hapticIntensity = UserDefaults.standard.string(forKey: "watchHapticIntensity") ?? "medium"
        audioEnabled    = UserDefaults.standard.object(forKey: "watchAudioEnabled") as? Bool ?? true
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Public actions

    func requestScan() {
        let msg: [String: Any] = ["command": "scan_now"]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil)
        }
        WKInterfaceDevice.current().play(.click)
    }

    func cancelSOS() {
        sosActive = false
        let msg: [String: Any] = ["type": "sos_cancel"]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil)
        } else {
            WCSession.default.transferUserInfo(msg)
        }
    }

    func dismissSOSOverlay() {
        sosActive = false
    }

    // MARK: - Incoming message routing

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }

    private func handle(_ message: [String: Any]) {
        DispatchQueue.main.async {
            if let type = message["type"] as? String {
                switch type {
                case "sos_alert":
                    if message["active"] as? Bool == true {
                        self.sosActive = true
                        WKInterfaceDevice.current().play(.failure)
                    }
                case "sos_clear":
                    self.sosActive = false
                default:
                    break
                }
            }
            if let direction = message["direction"] as? String {
                self.lastDirection = direction
                self.playHaptic(for: direction)
            }
        }
    }

    // Apple Watch only exposes preset haptic types — no custom spatial patterns —
    // so each direction maps to a distinct preset + timing combo as a stand-in.
    private func playHaptic(for direction: String) {
        let device = WKInterfaceDevice.current()
        let intensity = hapticIntensity

        switch direction {
        case "left":
            device.play(.directionDown)
            if intensity == "high" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { device.play(.directionDown) }
            }
        case "right":
            device.play(.directionUp)
            if intensity == "high" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { device.play(.directionUp) }
            }
        case "up":
            device.play(.notification)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { device.play(.notification) }
        default:
            // /ws/haptics only ever sends left/right/up -- anything else here
            // means a malformed message got through, not a valid 4th sensor.
            if intensity != "low" { device.play(.click) }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isPhoneReachable = session.isReachable }
    }
}