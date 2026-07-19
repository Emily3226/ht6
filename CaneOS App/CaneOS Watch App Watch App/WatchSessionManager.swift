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

    /// Double-pinch (system Double Tap gesture) → wake the phone's voice
    /// assistant so the user can just start talking. Distinct haptics
    /// confirm whether the phone actually got the request.
    func requestVoiceWake() {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["command": "wake_voice"], replyHandler: nil)
            WKInterfaceDevice.current().play(.start)
        } else {
            WKInterfaceDevice.current().play(.failure)
        }
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
                // The phone's intensity setting rides along with each buzz;
                // adopt it so the Watch always matches the phone app.
                if let intensity = message["intensity"] as? String {
                    self.hapticIntensity = intensity
                }
                self.lastDirection = direction
                self.playHaptic(for: direction)
            }
        }
    }

    /// Settings mirrored from the phone (fire-and-forget, latest value wins).
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            if let intensity = applicationContext["hapticIntensity"] as? String {
                self.hapticIntensity = intensity
            }
        }
    }

    // Apple Watch only exposes preset haptic types — no custom spatial
    // patterns, and no amplitude control. The navigation haptics
    // (.navigationLeftTurn/RightTurn) turned out not to produce a feelable
    // buzz outside an active navigation session. And on a single wrist,
    // similar presets at the same rhythm are hard to tell apart — so left
    // and right differ in BOTH haptic weight and rhythm:
    //   left  → slow, heavy thuds       (.failure, ~0.60s apart)  "THUD……THUD……"
    //   right → rapid-fire ripple       (.success, ~0.16s apart)  "dududududu"
    //   up    → steady rising two-tones (.directionUp, 0.25s apart)
    // Perceived strength comes from repetition; the intensity setting from
    // the phone app scales the pattern length.
    private func playHaptic(for direction: String) {
        let device = WKInterfaceDevice.current()

        let haptic: WKHapticType
        let gap: TimeInterval
        let baseCount: Int   // pulses at "low"; scaled up by intensity below
        switch direction {
        case "left":  haptic = .failure;     gap = 0.60; baseCount = 2
        case "right": haptic = .success;     gap = 0.16; baseCount = 5
        case "up":    haptic = .directionUp; gap = 0.25; baseCount = 2
        default:
            // /ws/haptics only ever sends left/right/up -- anything else here
            // means a malformed message got through, not a valid 4th sensor.
            if hapticIntensity != "low" { device.play(.click) }
            return
        }

        let multiplier: Int
        switch hapticIntensity {
        case "low":  multiplier = 1
        case "high": multiplier = 3
        default:     multiplier = 2
        }
        let repeats = baseCount * multiplier

        // Timer-app-strength trick: lead with a heavy .notification thump
        // (the same haptic family the system Timer alert uses) to grab the
        // wrist, then play the direction-identifying rhythm.
        device.play(.notification)
        for i in 0..<repeats {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40 + Double(i) * gap) {
                device.play(haptic)
            }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isPhoneReachable = session.isReachable }
    }
}