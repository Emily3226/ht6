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
    /// Voice session control from the Watch: "start" / "stop" / "cancel".
    var onVoiceControl: ((String) -> Void)?
    /// Raw Watch-mic audio chunks (16 kHz mono Int16 PCM).
    var onVoiceAudio: ((Data) -> Void)?
    /// Watch cancelled the SOS countdown (cancel button on the overlay).
    var onSOSCancel: (() -> Void)?

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
        if let control = message["voice"] as? String {
            DispatchQueue.main.async { self.onVoiceControl?(control) }
            return
        }
        if message["type"] as? String == "sos_cancel" {
            DispatchQueue.main.async { self.onSOSCancel?() }
            return
        }
        guard let command = message["command"] as? String else { return }
        DispatchQueue.main.async {
            switch command {
            case "wake_voice": self.onVoiceWake?()
            case "scan_now":   self.onWatchScanRequest?()
            default: break
            }
        }
    }

    /// Fallback delivery path: the Watch sends sos_cancel via
    /// transferUserInfo when it isn't "reachable" -- still honor it.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo["type"] as? String == "sos_cancel" {
            DispatchQueue.main.async { self.onSOSCancel?() }
        }
    }

    /// Watch-mic audio stream (each chunk is one converted PCM buffer).
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        DispatchQueue.main.async { self.onVoiceAudio?(messageData) }
    }

    /// Mirrors voice-assistant state/transcript/answers to the Watch UI.
    func sendVoiceUpdate(_ payload: [String: Any]) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(payload, replyHandler: nil)
    }

    /// Ships synthesized answer audio (MP3) to the Watch for playback there.
    /// Returns false when the Watch isn't reachable so the caller can fall
    /// back to phone playback.
    func sendAnswerAudio(_ data: Data) -> Bool {
        guard WCSession.default.isReachable else { return false }
        WCSession.default.sendMessageData(data, replyHandler: nil, errorHandler: nil)
        return true
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