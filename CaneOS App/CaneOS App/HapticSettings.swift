import Foundation
import WatchConnectivity
import Combine

/// How strong the Watch buzz feels. watchOS doesn't expose true variable-intensity
/// haptics to third-party apps (no Core Haptics on watchOS) — so "strength" here is
/// simulated by how many times the haptic repeats and how tight the gap is.
enum HapticIntensity: Int, CaseIterable, Identifiable {
    case light = 0
    case medium = 1
    case strong = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    /// How many times the haptic fires in a row.
    var repeatCount: Int {
        switch self {
        case .light: return 1
        case .medium: return 2
        case .strong: return 4
        }
    }

    /// Gap between repeats, in seconds.
    var repeatInterval: TimeInterval {
        switch self {
        case .light: return 0.0
        case .medium: return 0.22
        case .strong: return 0.18
        }
    }
}

/// Single source of truth for haptic settings on the phone. Persists to
/// UserDefaults locally and mirrors the value to the Watch any time it changes,
/// so the Watch always buzzes at whatever strength was last set on the phone.
final class HapticSettings: NSObject, ObservableObject {
    static let shared = HapticSettings()

    private let key = "hapticIntensity"

    @Published var intensity: HapticIntensity {
        didSet { persistAndSync() }
    }

    private override init() {
        let raw = UserDefaults.standard.object(forKey: key) as? Int
        self.intensity = raw.flatMap(HapticIntensity.init(rawValue:)) ?? .medium
        super.init()
    }

    private func persistAndSync() {
        UserDefaults.standard.set(intensity.rawValue, forKey: key)

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        // updateApplicationContext is the right tool here (not sendMessage):
        // it's fire-and-forget, doesn't need the Watch app to be foregrounded/reachable,
        // and only the latest value is delivered -- exactly what a settings value needs.
        do {
            try session.updateApplicationContext(["hapticIntensity": intensity.rawValue])
        } catch {
            print("Failed to sync haptic settings to Watch: \(error.localizedDescription)")
        }
    }
}
