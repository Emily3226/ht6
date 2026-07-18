import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum HapticIntensity: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum SensitivityLevel: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Published var hapticIntensity: HapticIntensity {
        didSet { UserDefaults.standard.set(hapticIntensity.rawValue, forKey: "hapticIntensity") }
    }
    @Published var sensitivityLevel: SensitivityLevel {
        didSet { UserDefaults.standard.set(sensitivityLevel.rawValue, forKey: "sensitivityLevel") }
    }
    @Published var audioEnabled: Bool {
        didSet { UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled") }
    }

    private init() {
        hapticIntensity = HapticIntensity(rawValue: UserDefaults.standard.string(forKey: "hapticIntensity") ?? "") ?? .medium
        sensitivityLevel = SensitivityLevel(rawValue: UserDefaults.standard.string(forKey: "sensitivityLevel") ?? "") ?? .medium
        audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true
    }
}
