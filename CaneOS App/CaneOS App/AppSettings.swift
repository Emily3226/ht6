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
        didSet {
            UserDefaults.standard.set(hapticIntensity.rawValue, forKey: "hapticIntensity")
            pushIfLoggedIn()
        }
    }
    @Published var sensitivityLevel: SensitivityLevel {
        didSet {
            UserDefaults.standard.set(sensitivityLevel.rawValue, forKey: "sensitivityLevel")
            pushIfLoggedIn()
        }
    }
    @Published var audioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled")
            pushIfLoggedIn()
        }
    }

    /// Set to true while applying values pulled from Atlas so the didSet
    /// observers don't immediately push those same values back up.
    private var isLoadingFromAtlas = false

    private init() {
        hapticIntensity  = HapticIntensity(rawValue: UserDefaults.standard.string(forKey: "hapticIntensity") ?? "") ?? .medium
        sensitivityLevel = SensitivityLevel(rawValue: UserDefaults.standard.string(forKey: "sensitivityLevel") ?? "") ?? .medium
        audioEnabled     = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true
    }

    // MARK: - Atlas sync

    private func pushIfLoggedIn() {
        guard !isLoadingFromAtlas else { return }
        Task { @MainActor in
            guard let uid = AuthManager.shared.userId else { return }
            await pushToAtlas(userId: uid)
        }
    }

    @MainActor
    func pushToAtlas(userId: String) async {
        let doc: [String: Any] = [
            "userId":          userId,
            "hapticIntensity": hapticIntensity.rawValue,
            "sensitivityLevel": sensitivityLevel.rawValue,
            "audioEnabled":    audioEnabled
        ]
        do {
            try await AtlasClient.shared.replaceOne(
                collection: "settings",
                filter: ["userId": userId],
                replacement: doc
            )
        } catch {
            print("[Atlas] pushSettings error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func pullFromAtlas(userId: String) async {
        do {
            let docs = try await AtlasClient.shared.find(collection: "settings",
                                                          filter: ["userId": userId])
            guard let doc = docs.first else {
                // No cloud settings yet — seed Atlas with current local values.
                await pushToAtlas(userId: userId)
                return
            }
            isLoadingFromAtlas = true
            if let v = doc["hapticIntensity"] as? String,
               let h = HapticIntensity(rawValue: v)  { hapticIntensity  = h }
            if let v = doc["sensitivityLevel"] as? String,
               let s = SensitivityLevel(rawValue: v) { sensitivityLevel = s }
            if let a = doc["audioEnabled"] as? Bool  { audioEnabled     = a }
            isLoadingFromAtlas = false
        } catch {
            print("[Atlas] pullSettings error: \(error.localizedDescription)")
        }
    }
}
