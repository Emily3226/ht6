import Foundation
import WatchConnectivity
import WatchKit

/// Mirrors HapticIntensity from the phone side. watchOS has no Core Haptics for
/// third-party apps, so "strength" is simulated via repeat count / interval.
enum HapticIntensity: Int {
    case light = 0
    case medium = 1
    case strong = 2

    var repeatCount: Int {
        switch self {
        case .light: return 1
        case .medium: return 2
        case .strong: return 4
        }
    }

    var repeatInterval: TimeInterval {
        switch self {
        case .light: return 0.0
        case .medium: return 0.22
        case .strong: return 0.18
        }
    }
}

final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()
    @Published var lastDirection: String = "-"

    private let intensityKey = "hapticIntensity"
    private var intensity: HapticIntensity {
        let raw = UserDefaults.standard.object(forKey: intensityKey) as? Int
        return raw.flatMap(HapticIntensity.init(rawValue:)) ?? .medium
    }

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

    // Settings changes arrive here (fire-and-forget, doesn't need the app foregrounded).
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let raw = applicationContext["hapticIntensity"] as? Int {
            UserDefaults.standard.set(raw, forKey: intensityKey)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let direction = message["direction"] as? String else { return }
        DispatchQueue.main.async {
            self.lastDirection = direction
            self.playHaptic(for: direction)
        }
    }

    // Apple Watch only exposes preset haptic types -- no true variable-intensity
    // patterns -- so each direction gets a distinct preset, repeated according to
    // the user's chosen strength as a stand-in for real intensity control.
    func playHaptic(for direction: String) {
        let device = WKInterfaceDevice.current()
        let type: WKHapticType
        switch direction {
        case "left": type = .directionDown
        case "right": type = .directionUp
        case "up": type = .notification
        case "down": type = .failure // distinct pattern for drop-off warning
        default: type = .click
        }

        let settings = intensity
        for i in 0..<settings.repeatCount {
            let delay = Double(i) * settings.repeatInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { device.play(type) }
        }
    }
}